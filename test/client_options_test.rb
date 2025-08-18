require_relative "test_helper"

class ClientOptionsTest < Minitest::Test
  def test_catalog_url_invalid_url
    error = assert_raises(URI::InvalidURIError) do
      new_client(catalog_url: "invalid url")
    end
    assert_match "bad URI", error.message
  end

  def test_catalog_url_extra_host
    error = assert_raises(ArgumentError) do
      new_client(catalog_url: "sqlite://db.sqlite")
    end
    assert_match "Unexpected host in catalog_url", error.message
  end

  def test_catalog_url_extra_query_params
    error = assert_raises(ArgumentError) do
      new_client(catalog_url: "sqlite:///db.sqlite?hello")
    end
    assert_match "Invalid catalog_url", error.message
  end

  def test_catalog_url_missing_path
    error = assert_raises(ArgumentError) do
      new_client(catalog_url: "sqlite:///")
    end
    assert_match "Invalid catalog_url", error.message
  end

  def test_catalog_url_unsupported_type
    error = assert_raises(ArgumentError) do
      new_client(catalog_url: "pg://")
    end
    assert_equal "Unsupported catalog type: pg", error.message
  end

  def test_storage_url_invalid_url
    error = assert_raises(URI::InvalidURIError) do
      new_client(storage_url: "invalid url")
    end
    assert_match "bad URI", error.message
  end

  def test_storage_options_unsupported
    error = assert_raises(ArgumentError) do
      new_client(storage_options: {a: "a", b: "b"})
    end
    assert_match(/Unsupported .+ storage options: :a, :b/, error.message)
  end

  def test_read_only
    client = new_client(_read_only: true)

    error = assert_raises(DuckLake::InvalidInputError) do
      client.sql("CREATE TABLE events (id integer)")
    end
    assert_match "attached in read-only mode", error.message

    error = assert_raises(DuckLake::IOError) do
      client.sql("ATTACH 'test/support/test.duckdb'")
    end
    assert_match "in read-only mode: database does not exist", error.message
  end

  def test_read_only_sql
    create_events(client)

    client = new_client(_read_only: true)
    assert_equal 3, client.sql("SELECT * FROM events").count

    # can still create external files if disable_external_access is not set
    client.sql("COPY events TO '/tmp/data.csv'")
    assert File.exist?("/tmp/data.csv")
  end

  def test_snapshot_version
    error = assert_raises(DuckLake::InvalidInputError) do
      new_client(snapshot_version: 1000000000)
    end
    assert_equal "No snapshot found at version 1000000000", error.message
  end

  def test_snapshot_time
    new_client(snapshot_time: Time.now)
    new_client(snapshot_time: DateTime.now)
  end

  def test_snapshot_version_snapshot_time
    error = assert_raises(DuckLake::InvalidInputError) do
      new_client(snapshot_version: 1, snapshot_time: Date.today)
    end
    assert_equal "Cannot specify both VERSION and TIMESTAMP", error.message
    assert_nil error.cause
  end

  def test_create_if_not_exists
    error = assert_raises(DuckLake::InvalidInputError) do
      new_client(catalog_url: "sqlite:////tmp/empty.sqlite")
    end
    assert_match "creating a new DuckLake is explicitly disabled", error.message
  end
end
