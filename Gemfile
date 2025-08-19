source "https://rubygems.org"

gemspec

gem "rake"
gem "minitest"
gem "bigdecimal"
gem "pg", require: false

if ENV["TEST_POLARS"]
  gem "polars-df", ">= 0.21.1"
end
