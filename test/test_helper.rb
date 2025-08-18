require "bundler/setup"
Bundler.require(:default)
require "minitest/autorun"

$catalog = ENV["CATALOG"] || "postgres"
puts "Using #{$catalog}"

class Minitest::Test
  def setup
    @@once ||= new_client(create_if_not_exists: true)

    client.drop_table("events", if_exists: true)
  end

  def teardown
    clients.each(&:disconnect)
  end

  def storage_url
    @@storage_url ||= ENV["STORAGE_URL"] || "/tmp/ducklake"
  end

  def catalog_url
    @@catalog_url ||=
      case $catalog
      when "postgres"
        "postgres://localhost/ducklake_ruby_test"
      when "mysql"
        "mysql://localhost/ducklake_ruby_test"
      when "mariadb"
        "mariadb://localhost/ducklake_ruby_test"
      when "sqlite"
        "sqlite:///#{tmpdir}/ducklake.sqlite"
      when "duckdb"
        "duckdb:///#{tmpdir}/ducklake.duckdb"
      else
        raise "Unsupported catalog"
      end
  end

  def client_options
    {
      catalog_url: catalog_url,
      storage_url: storage_url
    }
  end

  def new_client(**options)
    # disconnect previous client for DuckDB to ensure only one at a time
    clients.last&.disconnect if duckdb?

    client = DuckLake::Client.new(**client_options, **options)
    clients << client
    client
  end

  def clients
    @clients ||= []
  end

  def client
    @client ||= new_client
  end

  def duckdb?
    $catalog == "duckdb"
  end

  # TODO clean-up
  def tmpdir
    @@tmpdir ||= Dir.mktmpdir
  end

  def create_events(client = self.client)
    client.sql("CREATE TABLE events AS FROM 'test/support/data.csv'")
  end

  def load_events(client = self.client)
    client.sql("COPY events FROM 'test/support/data.csv'")
  end

  def clear_snapshots
    client.expire_snapshots(older_than: Time.now)
  end

  def clear_old_files
    clear_snapshots
    client.cleanup_old_files(cleanup_all: true)
  end
end
