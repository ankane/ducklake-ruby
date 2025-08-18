require_relative "lib/ducklake/version"

Gem::Specification.new do |spec|
  spec.name          = "ducklake"
  spec.version       = DuckLake::VERSION
  spec.summary       = "DuckLake for Ruby"
  spec.homepage      = "https://github.com/ankane/ducklake-ruby"
  spec.license       = "MIT"

  spec.author        = "Andrew Kane"
  spec.email         = "andrew@ankane.org"

  spec.files         = Dir["*.{md,txt}", "{lib}/**/*"]
  spec.require_path  = "lib"

  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "duckdb"
end
