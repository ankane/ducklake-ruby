require_relative "test_helper"

class ClientTest < Minitest::Test
  def test_snapshots
    clear_snapshots

    assert_equal 1, client.snapshots.size
    create_events
    assert_equal 2, client.snapshots.size
    load_events
    assert_equal 3, client.snapshots.size
  end

  def test_current_snapshot
    snapshot_id = client.current_snapshot
    create_events
    assert_equal snapshot_id + 1, client.current_snapshot
  end

  def test_last_committed_snapshot
    create_events
    assert_kind_of Integer, client.last_committed_snapshot
  end

  def test_schema_evolution
    create_events
    client.sql("ALTER TABLE events ADD COLUMN c VARCHAR DEFAULT 'hello'")
    result = client.sql("SELECT * FROM events")
    assert_equal ["a", "b", "c"], result.columns
    assert_equal "hello", result.first["c"]
  end

  def test_type_promotion
    client.sql("CREATE TABLE events (id INTEGER)")

    error = assert_raises(DuckLake::CatalogError) do
      client.sql("ALTER TABLE events ALTER COLUMN id TYPE SMALLINT")
    end
    assert_match "only widening type promotions are allowed", error.message

    client.sql("ALTER TABLE events ALTER COLUMN id TYPE BIGINT")
  end

  def test_time_travel
    # TODO this should not be needed
    clear_snapshots

    create_events
    snapshot_version = client.snapshots.last[:snapshot_id]

    client.sql("ALTER TABLE events RENAME to events2")
    client.sql("SELECT * FROM events AT (VERSION => ?)", [snapshot_version])
    assert_raises(DuckLake::CatalogError) do
      client.sql("SELECT * FROM events")
    end

    client2 = new_client(snapshot_version: snapshot_version)
    client2.sql("SELECT * FROM events")
    assert_raises(DuckLake::CatalogError) do
      client2.sql("SELECT * FROM events2")
    end

    client = new_client
    client.drop_table("events2")
  end

  def test_options
    assert_kind_of Array, client.options
  end

  # note: ducklake_set_option creates duplicate entries
  def test_set_option_global
    client.set_option("parquet_compression", "snappy")
    option = client.options.find { |v| v[:option_name] == "parquet_compression" && v[:scope] == "GLOBAL" }
    assert_equal "snappy", option[:value]
  end

  # note: ducklake_set_option creates duplicate entries
  def test_set_option_table
    create_events
    client.set_option("parquet_compression", "zstd", table_name: "events")
    option = client.options.find { |v| v[:option_name] == "parquet_compression" && v[:scope] == "TABLE" && v[:scope_entry] == "main.events" }
    assert_equal "zstd", option[:value]
  end

  def test_set_option_unsupported
    error = assert_raises(DuckLake::NotImplementedError) do
      client.set_option("hello", "world")
    end
    assert_equal "Unsupported option hello", error.message
  end

  def test_format_version
    assert_equal "0.3", client.format_version
  end

  def test_merge_adjacent_files
    create_events
    load_events
    assert_equal 2, client.list_files("events").size

    assert_nil client.merge_adjacent_files
    assert_equal 1, client.list_files("events").size
  end

  def test_expire_snapshots
    clear_snapshots

    assert_equal 0, client.expire_snapshots(older_than: Time.now).size
    assert_equal 1, client.snapshots.size

    create_events
    assert_equal 2, client.snapshots.size

    assert_equal 1, client.expire_snapshots(older_than: Time.now, dry_run: true).size
    assert_equal 2, client.snapshots.size

    assert_equal 1, client.expire_snapshots(older_than: Time.now).size
    assert_equal 1, client.snapshots.size
  end

  def test_expire_snapshots_versions
    client.expire_snapshots(versions: [1]).size
    client.expire_snapshots(versions: 1..2).size
  end

  def test_cleanup_old_files
    clear_old_files

    create_events
    client.drop_table("events")

    assert_equal 0, client.cleanup_old_files(cleanup_all: true, dry_run: true).size

    client.expire_snapshots(older_than: Time.now)
    assert_equal 1, client.cleanup_old_files(cleanup_all: true, dry_run: true).size
    assert_equal 1, client.cleanup_old_files(cleanup_all: true).size
  end

  def test_delete_orphaned_files
    client.cleanup_old_files(cleanup_all: true)
    assert_empty client.cleanup_old_files(cleanup_all: true)
  end

  def test_rewrite_data_files
    create_events
    client.sql("DELETE FROM events WHERE a > 1")

    assert_nil client.rewrite_data_files(delete_threshold: 0.5)

    files = client.list_files("events")
    assert_equal 1, files.size
    assert_nil files[0][:delete_file]
  end

  def test_list_files
    clear_old_files

    create_events
    assert_equal 1, client.list_files("events").size

    snapshot = client.snapshots.last

    load_events
    assert_equal 2, client.list_files("events").size

    assert_equal 1, client.list_files("events", snapshot_version: snapshot[:snapshot_id]).size
    # TODO figure out why this sometimes returns two files
    # assert_equal 1, client.list_files("events", snapshot_time: snapshot[:snapshot_time]).size
  end

  def test_add_data_files
    create_events
    assert_equal 1, client.list_files("events").size
    assert_equal 3, client.sql("SELECT * FROM events").count

    Dir.mktmpdir do |tmpdir|
      # note: add_data_files transfers ownership to DuckLake
      # which can delete the files
      # https://ducklake.select/docs/stable/duckdb/metadata/adding_files
      FileUtils.cp "test/support/data.parquet", tmpdir
      client.add_data_files("events", "#{tmpdir}/*.parquet")
      assert_equal 2, client.list_files("events").size
      assert_equal 6, client.sql("SELECT * FROM events").count
    end

    error = assert_raises(DuckLake::IOError) do
      client.sql("SELECT * FROM events").count
    end
    assert_match "Cannot open file", error.message

    error = assert_raises(DuckLake::IOError) do
      client.add_data_files("events", "test/support/missing.parquet")
    end
    assert_match "No files found that match the pattern", error.message

    error = assert_raises(DuckLake::InvalidInputError) do
      client.add_data_files("events", "test/support/data.csv")
    end
    assert_match "No magic bytes found", error.message
  end

  def test_data_inlining
    skip unless duckdb?

    client = new_client(data_inlining_row_limit: 10)
    create_events(client)
    assert_equal 0, client.list_files("events").size

    client.flush_inlined_data
    assert_equal 1, client.list_files("events").size
  end

  def test_table_info
    create_events
    info = client.table_info
    assert_equal 1, info.size
    assert_equal "events", info[0][:table_name]
  end

  def test_column_info
    create_events
    columns = client.column_info("events")
    expected = [{name: "a", type: "bigint"}, {name: "b", type: "varchar"}]
    assert_equal expected, columns
  end

  def test_column_info_missing
    error = assert_raises(DuckLake::CatalogError) do
      client.column_info("events")
    end
    assert_equal "Table does not exist!", error.message
  end

  def test_table_changes
    snapshot = client.snapshots.last[:snapshot_id]
    create_events
    snapshot2 = client.snapshots.last[:snapshot_id]
    client.sql("DELETE FROM events WHERE a = 2")
    snapshot3 = client.snapshots.last[:snapshot_id]
    assert_equal 3, client.table_changes("events", snapshot, snapshot2).size
    assert_equal 4, client.table_changes("events", snapshot, snapshot3).size
    assert_equal 1, client.table_changes("events", snapshot2, snapshot3).size
    assert_equal 0, client.table_changes("events", snapshot2, snapshot2).size
    assert_equal 0, client.table_changes("events", snapshot3, snapshot3).size
  end

  def test_table_changes_columns
    snapshot = client.snapshots.last[:snapshot_id]
    client.sql("CREATE TABLE events (snapshot_id bigint, rowid bigint, change_type varchar, snapshot_id_1 bigint)")
    client.sql("INSERT INTO events VALUES (1, 2, 'Test', 3)")
    snapshot2 = client.snapshots.last[:snapshot_id]
    result = client.table_changes("events", snapshot, snapshot2)
    expected = [:snapshot_id, :rowid, :change_type, :snapshot_id_1, :rowid_1, :change_type_1, :snapshot_id_1_1]
    assert_equal expected, result.first.keys
  end

  def test_drop_table
    create_events
    client.drop_table("events")
  end

  def test_drop_table_missing
    error = assert_raises(DuckLake::CatalogError) do
      client.drop_table("events")
    end
    assert_match "Table with name events does not exist!", error.message
  end

  def test_drop_table_if_exists
    create_events
    client.drop_table("events", if_exists: true)
    client.drop_table("events", if_exists: true)
  end

  def test_load_data_different_schema
    create_events

    error = assert_raises(DuckLake::InvalidInputError) do
      client.sql("COPY events FROM 'test/support/data2.csv'")
    end
    assert_match "does not match the number of columns", error.message

    error = assert_raises(DuckLake::ConversionError) do
      client.sql("COPY events FROM 'test/support/data3.csv'")
    end
    assert_match "Could not convert string \"one\" to 'BIGINT'", error.message
  end

  def test_attach_postgres
    require "pg"

    pg = PG.connect(dbname: "ducklake_ruby_test")
    pg.exec("DROP TABLE IF EXISTS postgres_events")
    pg.exec("CREATE TABLE postgres_events (id bigint, name text)")
    pg.exec_params("INSERT INTO postgres_events VALUES ($1, $2)", [1, "Test"])

    client.attach("pg", "postgres://localhost/ducklake_ruby_test")

    client.sql("CREATE TABLE events (id bigint, name text)")
    client.sql("INSERT INTO events SELECT * FROM pg.postgres_events")

    expected = [{"id" => 1, "name" => "Test"}]
    assert_equal expected, client.sql("SELECT * FROM events").to_a

    error = assert_raises(DuckLake::InvalidInputError) do
      client.sql("INSERT INTO pg.postgres_events VALUES (?, ?)", [2, "Test 2"])
    end
    assert_match "attached in read-only mode!", error.message

    client.detach("pg")
    error = assert_raises(DuckLake::CatalogError) do
      client.sql("INSERT INTO events SELECT * FROM pg.postgres_events")
    end
    assert_match "Table with name postgres_events does not exist!", error.message
  end

  def test_attach_unsupported_type
    error = assert_raises(ArgumentError) do
      client.attach("hello", "pg://")
    end
    assert_equal "Unsupported data source type: pg", error.message
  end

  def test_disable_external_access
    assert_nil client.disable_external_access

    error = assert_raises(DuckLake::PermissionError) do
      client.sql("ATTACH #{client.quote("#{tmpdir}/test.duckdb")}")
    end
    assert_match "file system operations are disabled by configuration", error.message
  end

  def test_disable_external_access_allowed_directories
    ensure_storage_path

    assert_nil client.disable_external_access(allowed_directories: ["test/support"])
    create_events

    assert_equal 3, client.sql("SELECT * FROM events").count

    error = assert_raises(DuckLake::PermissionError) do
      client.sql("ATTACH #{client.quote("#{tmpdir}/test.duckdb")}")
    end
    assert_match "file system operations are disabled by configuration", error.message
  end

  def test_disable_external_access_allowed_paths
    ensure_storage_path

    assert_nil client.disable_external_access(allowed_paths: ["test/support/data.csv"])
    create_events

    assert_equal 3, client.sql("SELECT * FROM events").count

    error = assert_raises(DuckLake::PermissionError) do
      client.sql("COPY events FROM 'test/support/data2.csv'")
    end
    assert_match "file system operations are disabled by configuration", error.message
  end

  def test_multiple_clients
    skip "Single client" if duckdb?

    client2 = new_client

    create_events
    load_events(client2)

    result = client.sql("SELECT * FROM events").to_a
    result2 = client2.sql("SELECT * FROM events").to_a
    assert_equal 6, result.size
    assert_equal result, result2
  end

  def test_different_storage_url
    client = new_client(storage_url: "#{tmpdir}/ducklake")
    create_events(client)

    error = assert_raises(DuckLake::InvalidConfigurationError) do
      new_client(storage_url: "#{tmpdir}/ducklake2", override_storage_url: false)
    end
    assert_match "does not match existing data path in the catalog", error.message

    client2 = new_client(storage_url: "#{tmpdir}/ducklake2")
    load_events(client2)

    error = assert_raises(DuckLake::IOError) do
      client2.sql("SELECT * FROM events")
    end
    assert_match "No such file or directory", error.message
  end

  def test_disconnect
    assert_nil client.disconnect
    error = assert_raises(DuckLake::Error) do
      client.sql("SELECT 1")
    end
    assert_equal "Failed to prepare statement(Database connection closed?).", error.message
  end

  def test_disconnect_multiple_times
    assert_nil client.disconnect
    assert_nil client.disconnect
  end

  def test_inspect
    assert_equal client.inspect, client.to_s
    refute_match "@db", client.inspect
  end

  private

  def ensure_storage_path
    if storage_url.start_with?("/") && !File.exist?(storage_url)
      Dir.mkdir(storage_url)
    end
  end
end
