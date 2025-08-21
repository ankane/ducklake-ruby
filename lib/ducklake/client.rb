module DuckLake
  class Client
    def initialize(
      catalog_url:,
      storage_url:,
      storage_options: {},
      snapshot_version: nil,
      snapshot_time: nil,
      data_inlining_row_limit: 0,
      create_if_not_exists: false,
      read_only: false # experimental
    )
      catalog_uri = URI.parse(catalog_url)
      storage_uri = URI.parse(storage_url)

      extension = nil
      case catalog_uri.scheme
      when "postgres", "postgresql"
        extension = "postgres"
        attach = "postgres:#{catalog_uri}"
      when "mysql", "mariadb"
        extension = "mysql"
        attach = "mysql:#{catalog_uri}"
      when "sqlite"
        extension = "sqlite"
        attach = "sqlite:#{catalog_path(catalog_uri)}"
      when "duckdb"
        attach = "duckdb:#{catalog_path(catalog_uri)}"
      else
        raise ArgumentError, "Unsupported catalog type: #{catalog_uri.scheme}"
      end

      @storage_scheme = storage_uri.scheme
      @storage_options = storage_options.dup

      secret_options = nil
      storage_options = storage_options.dup

      case storage_uri.scheme
      when "s3"
        # https://duckdb.org/docs/stable/core_extensions/httpfs/s3api.html
        key_id = storage_options.delete(:aws_access_key_id)
        secret = storage_options.delete(:aws_secret_access_key)
        region = storage_options.delete(:region)

        secret_options = {
          type: "s3",
          provider: "credential_chain"
        }
        secret_options[:key_id] = key_id if key_id
        secret_options[:secret] = secret if secret
        secret_options[:region] = region if region
      end

      if storage_options.any?
        raise ArgumentError, "Unsupported #{storage_uri.scheme || "file"} storage options: #{storage_options.keys.map(&:inspect).join(", ")}"
      end

      attach_options = {data_path: storage_url}
      attach_options[:read_only] = true if read_only
      attach_options[:snapshot_version] = snapshot_version if !snapshot_version.nil?
      attach_options[:snapshot_time] = snapshot_time if !snapshot_time.nil?
      attach_options[:data_inlining_row_limit] = data_inlining_row_limit if data_inlining_row_limit > 0
      attach_options[:create_if_not_exists] = false unless create_if_not_exists

      @catalog = "ducklake"
      @storage_url = storage_url

      if read_only
        config = DuckDB::Config.new
        config["access_mode"] = "READ_ONLY"

        # make the entire database read-only, not just DuckLake
        # read-only mode can only be set when the database is opened
        # and cannot be used on in-memory database, so create a temporary one
        @tmpdir = Dir.mktmpdir
        ObjectSpace.define_finalizer(@tmpdir, self.class.finalize(@tmpdir.dup))
        dbpath = File.join(@tmpdir, "memory.duckdb")
        DuckDB::Database.open(dbpath) { }

        @db = DuckDB::Database.open(dbpath, config)
      else
        @db = DuckDB::Database.open
      end

      @conn = @db.connect

      install_extension("ducklake")
      install_extension(extension) if extension
      create_secret(secret_options) if secret_options
      attach_with_options(@catalog, "ducklake:#{attach}", attach_options)
      execute("USE #{quote_identifier(@catalog)}")
      detach("memory")
    end

    # https://duckdb.org/docs/stable/operations_manual/securing_duckdb/overview.html#restricting-file-access
    def disable_external_access(allowed_directories: [], allowed_paths: [])
      allowed_directories += [@storage_url]
      execute("SET allowed_directories = #{quote_array(allowed_directories)}")
      execute("SET allowed_paths = #{quote_array(allowed_paths)}")
      execute("SET enable_external_access = false")
      nil
    end

    def sql(sql, params = [])
      execute(sql, params)
    end

    def transaction
      execute("BEGIN")
      begin
        yield
        execute("COMMIT")
      rescue => e
        execute("ROLLBACK")
        raise e unless e.is_a?(Rollback)
      end
    end

    def attach(alias_, url)
      type = nil
      extension = nil

      uri = URI.parse(url)
      case uri.scheme
      when "postgres", "postgresql"
        type = "postgres"
        extension = "postgres"
      else
        raise ArgumentError, "Unsupported data source type: #{uri.scheme}"
      end

      install_extension(extension) if extension

      options = {
        type: type,
        read_only: true
      }
      attach_with_options(alias_, url, options)
    end

    def detach(alias_)
      execute("DETACH #{quote_identifier(alias_)}")
      nil
    end

    def table_info
      symbolize_keys execute("SELECT * FROM ducklake_table_info(?)", [@catalog])
    end

    def column_info(table)
      sql = <<~SQL
        SELECT column_name AS name, LOWER(data_type) AS type
        FROM information_schema.columns
        WHERE table_catalog = ? AND table_schema = ? AND table_name = ?
        ORDER BY ordinal_position
      SQL
      result = execute(sql, [@catalog, "main", table])
      if result.empty?
        raise CatalogError, "Table does not exist!"
      end
      symbolize_keys result
    end

    # experimental
    # TODO use keyword arguments or range?
    def table_changes(table, start_snapshot, end_snapshot)
      params = [@catalog, "main", table, start_snapshot, end_snapshot]
      result = execute("SELECT * FROM ducklake_table_changes(?, ?, ?, ?, ?)", params)
      # only return changes between snapshots
      symbolize_keys result.reject { |v| v["snapshot_id"] == start_snapshot }
    end

    # TODO more DDL methods?
    def drop_table(table, if_exists: nil)
      execute("DROP TABLE#{" IF EXISTS" if if_exists} #{quote_identifier(table)}")
      nil
    end

    # https://ducklake.select/docs/stable/duckdb/usage/snapshots
    def snapshots
      symbolize_keys execute("SELECT * FROM ducklake_snapshots(?)", [@catalog])
    end

    # https://ducklake.select/docs/stable/duckdb/usage/configuration
    def options
      symbolize_keys execute("SELECT * FROM ducklake_options(?)", [@catalog])
    end

    # https://ducklake.select/docs/stable/duckdb/usage/configuration
    def set_option(name, value, table_name: nil)
      args = ["?", "?", "?"]
      params = [@catalog, name, value]

      if !table_name.nil?
        args << "table_name => ?"
        params << table_name
      end

      execute("CALL ducklake_set_option(#{args.join(", ")})", params)
      nil
    end

    def format_version
      execute("SELECT value FROM ducklake_options(?) WHERE option_name = ?", [@catalog, "version"]).first["value"]
    end

    # https://ducklake.select/docs/stable/duckdb/maintenance/merge_adjacent_files
    def merge_adjacent_files
      execute("CALL merge_adjacent_files()")
      nil
    end

    # https://ducklake.select/docs/stable/duckdb/maintenance/expire_snapshots
    def expire_snapshots(versions: nil, older_than: nil, dry_run: false)
      args = ["?"]
      params = [@catalog]

      if !versions.nil?
        # inline since duckdb gem does not support array params
        args << "versions => #{quote_array(versions)}"
      end

      if !older_than.nil?
        args << "older_than => ?"
        params << older_than
      end

      if dry_run
        args << "dry_run => ?"
        params << dry_run
      end

      symbolize_keys execute("CALL ducklake_expire_snapshots(#{args.join(", ")})", params)
    end

    # https://ducklake.select/docs/stable/duckdb/maintenance/cleanup_old_files
    def cleanup_old_files(cleanup_all: false, older_than: nil, dry_run: false)
      args = ["?"]
      params = [@catalog]

      if cleanup_all
        args << "cleanup_all => ?"
        params << cleanup_all
      end

      if !older_than.nil?
        args << "older_than => ?"
        params << older_than
      end

      if dry_run
        args << "dry_run => ?"
        params << dry_run
      end

      symbolize_keys execute("CALL ducklake_cleanup_old_files(#{args.join(", ")})", params)
    end

    # https://ducklake.select/docs/stable/duckdb/advanced_features/data_inlining
    def flush_inlined_data(table_name: nil)
      args = ["?"]
      params = [@catalog]

      if !table_name.nil?
        args << "table_name => ?"
        params << table_name
      end

      symbolize_keys execute("CALL ducklake_flush_inlined_data(#{args.join(", ")})", params)
    end

    # https://ducklake.select/docs/stable/duckdb/metadata/list_files
    def list_files(table, snapshot_version: nil, snapshot_time: nil)
      args = ["?", "?"]
      params = [@catalog, table]

      if !snapshot_version.nil?
        args << "snapshot_version => ?"
        params << snapshot_version
      end

      if !snapshot_time.nil?
        snapshot_time = snapshot_time.utc if snapshot_time.is_a?(Time)
        args << "snapshot_time => ?"
        params << snapshot_time
      end

      symbolize_keys execute("SELECT * FROM ducklake_list_files(#{args.join(", ")})", params)
    end

    # https://ducklake.select/docs/stable/duckdb/metadata/adding_files
    def add_data_files(table, data, allow_missing: nil, ignore_extra_columns: nil)
      params = [@catalog, table, data]
      args = ["?", "?", "?"]

      if !allow_missing.nil?
        args << "allow_missing => ?"
        params << allow_missing
      end

      if !ignore_extra_columns.nil?
        args << "ignore_extra_columns => ?"
        params << ignore_extra_columns
      end

      execute("CALL ducklake_add_data_files(#{args.join(", ")})", params)
      nil
    end

    # experimental
    def polars(table, snapshot_version: nil, snapshot_time: nil)
      files = list_files(table, snapshot_version:, snapshot_time:)
      sources = files.map { |v| v[:data_file] }
      # TODO support schema changes
      # column_mapping = [
      #   "iceberg-column-mapping",
      #   nil
      # ]
      deletion_files = [
        "iceberg-position-delete",
        files.map.with_index.select { |v, i| v[:delete_file] }.to_h { |v, i| [i, [v[:delete_file]]] }
      ]
      Polars.scan_parquet(
        sources,
        storage_options: polars_storage_options,
        # allow_missing_columns: true,
        # extra_columns: "ignore",
        # _column_mapping: column_mapping,
        _deletion_files: deletion_files
      )
    end

    # libduckdb does not provide function
    # https://duckdb.org/docs/stable/sql/dialect/keywords_and_identifiers.html
    def quote_identifier(value)
      "\"#{encoded(value).gsub('"', '""')}\""
    end

    # libduckdb does not provide function
    # TODO support more types
    def quote(value)
      if value.nil?
        "NULL"
      elsif value == true
        "true"
      elsif value == false
        "false"
      elsif defined?(BigDecimal) && value.is_a?(BigDecimal)
        value.to_s("F")
      elsif value.is_a?(Numeric)
        value.to_s
      else
        if value.is_a?(Time)
          value = value.utc.iso8601(9)
        elsif value.is_a?(DateTime)
          value = value.iso8601(9)
        elsif value.is_a?(Date)
          value = value.strftime("%Y-%m-%d")
        end
        "'#{encoded(value).gsub("'", "''")}'"
      end
    end

    def disconnect
      @conn.disconnect
      @db.close
      nil
    end

    # hide internal state
    def inspect
      to_s
    end

    def self.finalize(dir)
      proc { FileUtils.remove_entry(dir) }
    end

    private

    def execute(sql, params = [])
      # use prepare instead of query to prevent multiple statements at once
      result =
        @conn.prepare(sql) do |stmt|
          params.each_with_index do |v, i|
            stmt.bind(i + 1, v)
          end
          stmt.execute
        end

      # TODO add column types
      Result.new(result.columns.map(&:name), result.to_a)
    rescue DuckDB::Error => e
      raise map_error(e), cause: nil
    end

    def error_mapping
      @error_mapping ||= {
        "Catalog Error: " => CatalogError,
        "Conversion Error: " => ConversionError,
        "Invalid Input Error: " => InvalidInputError,
        "IO Error: " => IOError,
        "Permission Error: " => PermissionError,
        "TransactionContext Error: " => TransactionContextError
      }
    end

    # not ideal to base on prefix, but do not see a better way at the moment
    def map_error(e)
      error_mapping.each do |prefix, cls|
        if e.message&.start_with?(prefix)
          return cls.new(e.message.delete_prefix(prefix))
        end
      end
      Error.new(e.message)
    end

    def install_extension(extension)
      execute("INSTALL #{quote_identifier(extension)}")
    end

    def create_secret(options)
      execute("CREATE SECRET (#{options_args(options)})")
    end

    def attach_with_options(alias_, url, options)
      execute("ATTACH #{quote(url)} AS #{quote_identifier(alias_)} (#{options_args(options)})")
    end

    def options_args(options)
      options.map { |k, v| "#{option_name(k)} #{quote(v)}" }.join(", ")
    end

    def option_name(k)
      name = k.to_s.upcase
      # should never contain user input, but just to be safe
      unless name.match?(/\A[A-Z_]+\z/)
        raise "Invalid option name"
      end
      name
    end

    def symbolize_keys(result)
      result.map { |v| v.transform_keys(&:to_sym) }
    end

    def catalog_path(uri)
      # custom message for sqlite://db.sqlite
      # TODO improve message
      if !uri.host.empty?
        raise ArgumentError, "Unexpected host in catalog_url"
      end

      if uri.path.length < 2 || uri.user || uri.password || uri.port || uri.query || uri.fragment
        raise ArgumentError, "Invalid catalog_url"
      end

      uri.path[1..]
    end

    def polars_storage_options
      @polars_storage_options ||= begin
        storage_options = {}
        extra_options = @storage_options.dup

        case @storage_scheme
        when "s3"
          # https://docs.rs/object_store/latest/object_store/aws/enum.AmazonS3ConfigKey.html
          [:aws_access_key_id, :aws_secret_access_key, :region].each do |k|
            storage_options[k] = extra_options.delete(k) if extra_options.key?(k)
          end
        end

        if extra_options.any?
          raise ArgumentError, "Unsupported #{@storage_scheme || "file"} storage options: #{extra_options.keys.map(&:inspect).join(", ")}"
        end

        storage_options
      end
    end

    def quote_array(value)
      "[#{value.map { |v| quote(v) }.join(", ")}]"
    end

    def encoded(value)
      value = value.to_s if value.is_a?(Symbol)
      if !value.respond_to?(:to_str)
        raise TypeError, "no implicit conversion of #{value.class.name} into String"
      end
      if ![Encoding::UTF_8, Encoding::US_ASCII].include?(value.encoding) || !value.valid_encoding?
        raise ArgumentError, "Unsupported encoding"
      end
      value
    end
  end
end
