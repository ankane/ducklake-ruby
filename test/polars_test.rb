require_relative "test_helper"

class PolarsTest < Minitest::Test
  include Polars::Testing if ENV["TEST_POLARS"]

  def setup
    skip unless ENV["TEST_POLARS"]
    super
  end

  def test_snapshot_version
    create_events
    client.sql("INSERT INTO events VALUES (?, ?), (?, ?)", [4, "four", 5, "five"])
    client.sql("DELETE FROM events WHERE a = 2")
    snapshot = client.snapshots.last
    client.sql("DELETE FROM events WHERE a = 4")

    expected = Polars::DataFrame.new({"a" => [1, 3, 5], "b" => ["one", "three", "five"]})
    assert_frame_equal expected, client.polars("events").collect

    expected = Polars::DataFrame.new({"a" => [1, 3, 4, 5], "b" => ["one", "three", "four", "five"]})
    assert_frame_equal expected, client.polars("events", snapshot_version: snapshot[:snapshot_id]).collect
  end

  def test_rename
    create_events
    client.sql("ALTER TABLE events RENAME b TO c")
    client.sql("INSERT INTO events VALUES (?, ?), (?, ?)", [4, "four", 5, "five"])

    error = assert_raises(Polars::Error) do
      client.polars("events").collect
    end
    assert_match "extra column in file outside of expected schema: c", error.message
  end
end
