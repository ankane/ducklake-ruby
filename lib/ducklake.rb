# dependencies
require "duckdb"

# stdlib
require "uri"

# modules
require_relative "ducklake/client"
require_relative "ducklake/result"
require_relative "ducklake/version"

module DuckLake
  class Error < StandardError; end
  class CatalogError < Error; end
  class ConversionError < Error; end
  class InvalidInputError < Error; end
  class IOError < Error; end
  class PermissionError < Error; end
  class Rollback < Error; end
  class TransactionContextError < Error; end
end
