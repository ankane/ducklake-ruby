require_relative "test_helper"

class SqlTest < Minitest::Test
  def test_result
    create_events
    result = client.sql("SELECT * FROM events")
    assert_equal ["a", "b"], result.columns
    assert_equal [[1, "one"], [2, "two"], [3, "three"]], result.rows
    assert_equal [{"a" => 1, "b" => "one"}, {"a" => 2, "b" => "two"}, {"a" => 3, "b" => "three"}], result.to_a
    assert_equal ({"a" => 1, "b" => "one"}), result.first
    assert_equal false, result.empty?
  end

  def test_types
    assert_kind_of Integer, client.sql("SELECT 1").rows[0][0]
    assert_kind_of BigDecimal, client.sql("SELECT 1.0").rows[0][0]
    assert_kind_of Date, client.sql("SELECT current_date").rows[0][0]
    assert_kind_of Time, client.sql("SELECT current_time").rows[0][0]
    assert_kind_of TrueClass, client.sql("SELECT true").rows[0][0]
    assert_kind_of FalseClass, client.sql("SELECT false").rows[0][0]
    assert_kind_of NilClass, client.sql("SELECT NULL").rows[0][0]
  end

  def test_params
    assert_kind_of Integer, client.sql("SELECT ?", [1]).rows[0][0]
    assert_kind_of Float, client.sql("SELECT ?", [1.0]).rows[0][0]
    assert_kind_of BigDecimal, client.sql("SELECT ?", [BigDecimal("1")]).rows[0][0]
    assert_kind_of TrueClass, client.sql("SELECT ?", [true]).rows[0][0]
    assert_kind_of FalseClass, client.sql("SELECT ?", [false]).rows[0][0]
    assert_kind_of NilClass, client.sql("SELECT ?", [nil]).rows[0][0]
    # TODO try to fix
    assert_kind_of String, client.sql("SELECT ?", [Date.today]).rows[0][0]
    assert_kind_of String, client.sql("SELECT ?", [Time.now]).rows[0][0]
  end

  def test_view
    create_events
    client.sql("CREATE VIEW events_view AS SELECT a AS c, b AS d FROM events")
    result = client.sql("SELECT * FROM events_view")
    assert_equal ["c", "d"], result.columns
    assert_equal [[1, "one"], [2, "two"], [3, "three"]], result.rows
  ensure
    client.sql("DROP VIEW IF EXISTS events_view")
  end

  def test_partitioning
    client.sql("CREATE TABLE events (a bigint, b text)")
    client.sql("ALTER TABLE events SET PARTITIONED BY (a)")
    load_events
    assert_equal 3, client.list_files("events").size
  end

  def test_transaction
    client.transaction do
      create_events
      load_events
    end
    assert_equal 6, client.sql("SELECT * FROM events").count
  end

  def test_transaction_rollback
    create_events
    client.transaction do
      load_events
      raise DuckLake::Rollback
    end
    assert_equal 3, client.sql("SELECT * FROM events").count
  end

  def test_transaction_error
    create_events
    error = assert_raises do
      client.transaction do
        load_events
        raise "Error"
      end
    end
    assert_equal "Error", error.message
    assert_equal 3, client.sql("SELECT * FROM events").count
  end

  def test_transaction_nested
    error = assert_raises(DuckLake::TransactionContextError) do
      client.transaction do
        client.transaction do
        end
      end
    end
    assert_equal "cannot start a transaction within a transaction", error.message
  end

  def test_multiple_statements
    error = assert_raises(DuckLake::InvalidInputError) do
      client.sql("SELECT 1; SELECT 2").to_a
    end
    assert_equal "Cannot prepare multiple statements at once!", error.message
  end

  def test_quote_identifier
    assert_equal %{"events"}, client.quote_identifier("events")
    assert_equal %{"events"}, client.quote_identifier(:events)
    assert_equal %{"""events"""}, client.quote_identifier(%{"events"})

    error = assert_raises(TypeError) do
      client.quote_identifier(nil)
    end
    assert_equal "no implicit conversion of NilClass into String", error.message

    error = assert_raises(TypeError) do
      client.quote_identifier(Object.new)
    end
    assert_equal "no implicit conversion of Object into String", error.message
  end

  def test_quote_identifier_statement
    table = 19.times.map { ["a", "'", '"', "\\"].sample }.join
    client.sql("CREATE TABLE #{client.quote_identifier(table)} (a integer, b varchar)")
  ensure
    client.drop_table(table, if_exists: true)
  end

  def test_quote_identifier_schema
    create_events
    error = assert_raises(DuckLake::CatalogError) do
      client.sql("COPY #{client.quote_identifier("main.events")} FROM 'test/support/data.csv'")
    end
    assert_match "Table with name main.events does not exist!", error.message
    assert_equal 3, client.sql("SELECT * FROM main.events").count
  end

  def test_quote
    assert_equal "NULL", client.quote(nil)
    assert_equal "true", client.quote(true)
    assert_equal "false", client.quote(false)
    assert_equal "1", client.quote(1)
    assert_equal "0.5", client.quote(0.5)
    assert_equal "0.5", client.quote(BigDecimal("0.5"))
    assert_equal "'2025-01-02T03:04:05.123456000Z'", client.quote(Time.utc(2025, 1, 2, 3, 4, 5, 123456))
    assert_equal "'2025-01-02'", client.quote(Date.new(2025, 1, 2))
    assert_equal "'hello'", client.quote("hello")
    error = assert_raises(TypeError) do
      client.quote(Object.new)
    end
    assert_equal "no implicit conversion of Object into String", error.message
  end

  def test_quote_statement
    value = 19.times.map { ["a", "'", '"', "\\"].sample }.join
    assert_equal value, client.sql("SELECT #{client.quote(value)} AS value").rows[0][0]
  end
end
