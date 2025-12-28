require "bundler/gem_tasks"
require "rake/testtask"

CATALOGS = %w(postgres mysql sqlite duckdb)

CATALOGS.each do |catalog|
  namespace :test do
    task("env:#{catalog}") { ENV["CATALOG"] = catalog }

    Rake::TestTask.new(catalog => "env:#{catalog}") do |t|
      t.description = "Run tests for #{catalog}"
      t.test_files = FileList["test/**/*_test.rb"]
    end
  end
end

desc "Run all catalog tests"
task :test do
  CATALOGS.each do |catalog|
    # https://github.com/duckdb/ducklake/issues/70
    # https://github.com/duckdb/ducklake/issues/210
    next if catalog == "mysql"

    Rake::Task["test:#{catalog}"].invoke
  end
end

task default: :test
