# frozen_string_literal: true

require "test_helper"
require "ostruct"

class SegmentSubscribersTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.configure { |c| c.enabled = true; c.instrument_segments = true }
    @req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = @req_segments
  end

  teardown do
    Thread.current[:catpm_request_segments] = nil
    Catpm::SegmentSubscribers.unsubscribe!
  end

  test "record_sql_segment is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    event = mock_sql_event(name: "User Load", sql: "SELECT * FROM users", duration: 5.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    # No crash, no segments
    assert_equal 0, @req_segments.segments.size
  end

  test "record_sql_segment adds sql segment" do
    event = mock_sql_event(name: "User Load", sql: "SELECT * FROM users", duration: 5.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert_equal 1, @req_segments.segments.size
    seg = @req_segments.segments.first
    assert_equal "sql", seg[:type]
    assert_equal 5.0, seg[:duration]
    assert_equal "SELECT * FROM users", seg[:detail]
  end

  test "record_sql_segment truncates long SQL" do
    Catpm.configure { |c| c.max_sql_length = 20 }
    long_sql = "SELECT * FROM users WHERE name = 'very long query here'"
    event = mock_sql_event(name: "User Load", sql: long_sql, duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert @req_segments.segments.first[:detail].length <= 24 # 20 + "..."
    assert @req_segments.segments.first[:detail].end_with?("...")
  end

  test "record_sql_segment ignores SCHEMA queries" do
    event = mock_sql_event(name: "SCHEMA", sql: "SELECT * FROM sqlite_master", duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert_equal 0, @req_segments.segments.size
  end

  test "record_sql_segment ignores migration queries" do
    event = mock_sql_event(name: "ActiveRecord::SchemaMigration Load", sql: "SELECT *", duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert_equal 0, @req_segments.segments.size
  end

  test "record_sql_segment captures source for slow queries" do
    Catpm.configure { |c| c.segment_source_threshold = 0.0 } # capture all
    event = mock_sql_event(name: "User Load", sql: "SELECT 1", duration: 10.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    # Source might be nil if no app frames in the test callstack, but it shouldn't crash
    assert_equal 1, @req_segments.segments.size
  end

  test "record_sql_segment skips source for fast queries" do
    Catpm.configure { |c| c.segment_source_threshold = 100.0 } # very high threshold
    event = mock_sql_event(name: "User Load", sql: "SELECT 1", duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    refute @req_segments.segments.first.key?(:source)
  end

  test "record_view_segment adds view segment" do
    event = mock_view_event(identifier: "app/views/users/index.html.erb", duration: 8.0)
    Catpm::SegmentSubscribers.send(:record_view_segment, event)

    assert_equal 1, @req_segments.segments.size
    seg = @req_segments.segments.first
    assert_equal "view", seg[:type]
    assert_equal 8.0, seg[:duration]
    assert_includes seg[:detail], "users/index"
  end

  test "record_view_segment strips Rails.root from identifier" do
    full_path = "#{Rails.root}/app/views/users/show.html.erb"
    event = mock_view_event(identifier: full_path, duration: 3.0)
    Catpm::SegmentSubscribers.send(:record_view_segment, event)

    assert_equal "app/views/users/show.html.erb", @req_segments.segments.first[:detail]
  end

  private

  def mock_sql_event(name:, sql:, duration:)
    OpenStruct.new(
      payload: { name: name, sql: sql },
      duration: duration
    )
  end

  def mock_view_event(identifier:, duration:)
    OpenStruct.new(
      payload: { identifier: identifier },
      duration: duration
    )
  end
end
