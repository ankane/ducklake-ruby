# DuckLake Ruby

:duck: [DuckLake](https://ducklake.select/) for Ruby

Run your own data lake with a SQL database and file/object storage

```ruby
DuckLake::Client.new(
  catalog_url: "postgres://user:pass@host:5432/dbname",
  storage_url: "s3://my-bucket/"
)
```

[Learn more](https://duckdb.org/2025/05/27/ducklake.html)

Note: DuckLake is [not considered production-ready](https://ducklake.select/faq#is-ducklake-production-ready) at the moment

[![Build Status](https://github.com/ankane/ducklake-ruby/actions/workflows/build.yml/badge.svg)](https://github.com/ankane/ducklake-ruby/actions)

## Installation

First, install libduckdb. For Homebrew, use:

```sh
brew install duckdb
```

Then add this line to your application’s Gemfile:

```ruby
gem "ducklake"
```

## Getting Started

Create a client - this one stores everything locally

```ruby
ducklake =
  DuckLake::Client.new(
    catalog_url: "sqlite:///ducklake.sqlite",
    storage_url: "data_files/",
    create_if_not_exists: true
  )
```

Create a table

```ruby
ducklake.sql("CREATE TABLE events (id bigint, name text)")
```

Load data from a file

```ruby
ducklake.sql("COPY events FROM 'data.csv'")
```

Confirm a new Parquet file was added to the data lake

```ruby
ducklake.list_files("events")
```

Query the data

```ruby
ducklake.sql("SELECT COUNT(*) FROM events").to_a
```

## Catalog Database

Catalog information can be stored in:

- Postgres: `postgres://user@pass@host:5432/dbname`
- SQLite: `sqlite:///path/to/dbname.sqlite`
- DuckDB: `duckdb:///path/to/dbname.duckdb`

Note: MySQL and MariaDB are not currently supported due to [duckdb/ducklake#70](https://github.com/duckdb/ducklake/issues/70) and [duckdb/ducklake#210](https://github.com/duckdb/ducklake/issues/210)

There are two ways to set up the schema:

1. Run [this script](https://ducklake.select/docs/stable/specification/tables/overview#full-schema-creation-script)
2. Configure the client to do it

  ```ruby
  DuckLake::Client.new(create_if_not_exists: true, ...)
  ```

## Data Storage

Data can be stored in:

- Local files: `data_files/`
- Amazon S3: `s3://my-bucket/path/`
- [Other providers](https://ducklake.select/docs/stable/duckdb/usage/choosing_storage): todo

### Amazon S3

Credentials are detected in the standard AWS SDK locations, or you can pass them manually

```ruby
DuckLake::Client.new(
  storage_options: {
    aws_access_key_id: "...",
    aws_secret_access_key: "...",
    region: "us-east-1"
  },
  ...
)
```

IAM permissions

- Read: `s3::ListBucket`, `s3::GetObject`
- Write: `s3::ListBucket`, `s3::PutObject`
- Maintenance: `s3::ListBucket`, `s3::GetObject`, `s3::PutObject`, `s3::DeleteObject`

## Operations

Create an empty table

```ruby
ducklake.sql("CREATE TABLE events (id bigint, name text)")
```

Or a table from a file

```ruby
ducklake.sql("CREATE TABLE events AS FROM 'data.csv'")
```

Load data from a file

```ruby
ducklake.sql("COPY events FROM 'data.csv'")
```

You can also load data directly from other [data sources](https://duckdb.org/docs/stable/data/data_sources)

```ruby
ducklake.attach("blog", "postgres://localhost:5432/blog")
ducklake.sql("INSERT INTO events SELECT * FROM blog.ahoy_events")
```

Or [register existing data files](https://ducklake.select/docs/stable/duckdb/metadata/adding_files)

```ruby
ducklake.add_data_files("events", "data.parquet")
```

Note: This transfers ownership to the data lake, so the file may be deleted as part of [maintenance](#maintenance)

Update data

```ruby
ducklake.sql("UPDATE events SET name = ? WHERE id = 1", ["Test", 1])
```

Delete data

```ruby
ducklake.sql("DELETE * FROM events WHERE id = ?", [1])
```

Update the schema

```ruby
ducklake.sql("ALTER TABLE events ADD COLUMN active BOOLEAN")
```

## Snapshots

Get snapshots

```ruby
ducklake.snapshots
```

Query the data at a specific snapshot version or time

```ruby
ducklake.sql("SELECT * FROM events AT (VERSION => ?)", [3])
#
ducklake.sql("SELECT * FROM events AT (TIMESTAMP => ?)", [Date.today - 7])
```

You can also specify a snapshot when creating the client

```ruby
DuckLake::Client.new(snapshot_version: 3, ...)
# or
DuckLake::Client.new(snapshot_time: Date.today - 7, ...)
```

## Maintenance

Merge files

```ruby
ducklake.merge_adjacent_files
```

Expire snapshots

```ruby
ducklake.expire_snapshots(older_than: Date.today - 7)
```

Clean up old files

```ruby
ducklake.cleanup_old_files(older_than: Date.today - 7)
```

## Configuration

Get [options](https://ducklake.select/docs/stable/duckdb/usage/configuration)

```ruby
ducklake.options
```

Set an option globally

```ruby
ducklake.set_option("parquet_compression", "zstd")
```

Or for a specific table

```ruby
ducklake.set_option("parquet_compression", "zstd", table_name: "events")
```

## Read-Only Mode

Note: This feature is experimental

Connect to the data lake in read-only mode

```ruby
DuckLake::Client.new(_read_only: true, ...)
```

Use read-only credentials for catalog database and storage provider and [disable external access](#external-access)

You should also consider [disabling community extensions](https://duckdb.org/docs/stable/operations_manual/securing_duckdb/securing_extensions.html#community-extensions)

```ruby
ducklake.sql("SET allow_community_extensions = false")
```

And [locking the configuration](https://duckdb.org/docs/stable/operations_manual/securing_duckdb/overview.html#locking-configurations)

```ruby
ducklake.sql("SET lock_configuration = true")
```

## External Access

[Restrict external access](https://duckdb.org/docs/stable/operations_manual/securing_duckdb/overview.html#restricting-file-access) to the DuckDB engine

```ruby
ducklake.disable_external_access
```

Allow specific directories and paths

```ruby
ducklake.disable_external_access(
  allowed_directories: ["/path/to/directory"],
  allowed_paths: ["/path/to/file.txt"]
)
```

The storage URL is automatically included in `allowed_directories`

## SQL Safety

Use parameterized queries when possible

```ruby
ducklake.sql("SELECT * FROM events WHERE id = ?", [1])
```

For places that do not support parameters, use `quote` or `quote_identifier`

```ruby
quoted_table = ducklake.quote_identifier("events")
quoted_file = ducklake.quote("path/to/data.csv")
ducklake.sql("COPY #{quoted_table} FROM #{quoted_file}")
```

## Polars

Note: This feature is experimental and does not work on tables with schema changes. [unreleased]

Query the data with [Ruby Polars](https://github.com/ankane/ruby-polars)

```ruby
ducklake.polars("events")
```

Specify a snapshot

```ruby
ducklake.polars("events", snapshot_version: 3)
# or
ducklake.polars("events", snapshot_time: Date.today - 7)
```

## Reference

Get table info

```ruby
ducklake.table_info
```

Get column info

```ruby
ducklake.column_info("events")
```

Drop a table

```ruby
ducklake.drop_table("events")
# or
ducklake.drop_table("events", if_exists: true)
```

List files

```ruby
ducklake.list_files("events")
```

List files at a specific snapshot version or time

```ruby
ducklake.list_files("events", snapshot_version: 3)
# or
ducklake.list_files("events", snapshot_time: Date.today - 7)
```

## History

View the [changelog](https://github.com/ankane/ducklake-ruby/blob/master/CHANGELOG.md)

## Contributing

Everyone is encouraged to help improve this project. Here are a few ways you can help:

- [Report bugs](https://github.com/ankane/ducklake-ruby/issues)
- Fix bugs and [submit pull requests](https://github.com/ankane/ducklake-ruby/pulls)
- Write, clarify, or fix documentation
- Suggest or add new features

To get started with development:

```sh
git clone https://github.com/ankane/ducklake-ruby.git
cd ducklake-ruby
bundle install

# Postgres
createdb ducklake_ruby_test
bundle exec rake test:postgres

# MySQL and MariaDB
mysqladmin create ducklake_ruby_test
bundle exec rake test:mysql

# SQLite
bundle exec rake test:sqlite

# DuckDB
bundle exec rake test:duckdb
```
