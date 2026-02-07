# frozen_string_literal: true

require "test_helper"

class RequestSegmentsTest < ActiveSupport::TestCase
  test "initializes with empty segments and zero summary" do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    assert_equal [], rs.segments
    assert_equal 0, rs.summary[:sql_count]
    assert_equal 0.0, rs.summary[:sql_duration]
    assert_equal 0, rs.summary[:view_count]
    assert_equal 0.0, rs.summary[:view_duration]
    refute rs.overflowed?
  end

  test "add appends sql segment and updates summary" do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 12.345, detail: "SELECT * FROM users")

    assert_equal 1, rs.segments.size
    seg = rs.segments.first
    assert_equal "sql", seg[:type]
    assert_equal 12.35, seg[:duration]
    assert_equal "SELECT * FROM users", seg[:detail]
    assert_nil seg[:source]

    assert_equal 1, rs.summary[:sql_count]
    assert_in_delta 12.345, rs.summary[:sql_duration], 0.01
  end

  test "add appends view segment and updates summary" do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :view, duration: 8.3, detail: "app/views/users/index.html.erb")

    assert_equal 1, rs.segments.size
    assert_equal "view", rs.segments.first[:type]
    assert_equal 1, rs.summary[:view_count]
    assert_in_delta 8.3, rs.summary[:view_duration], 0.01
  end

  test "add includes source when provided" do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 15.0, detail: "SELECT 1", source: "app/models/user.rb:42")

    assert_equal "app/models/user.rb:42", rs.segments.first[:source]
  end

  test "add omits source key when nil" do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 1.0, detail: "SELECT 1")

    refute rs.segments.first.key?(:source)
  end

  test "caps segments at max and replaces fastest with slower" do
    rs = Catpm::RequestSegments.new(max_segments: 3)
    rs.add(type: :sql, duration: 10.0, detail: "Q1")
    rs.add(type: :sql, duration: 5.0, detail: "Q2")
    rs.add(type: :sql, duration: 15.0, detail: "Q3")

    # At capacity — now add a slower one
    rs.add(type: :sql, duration: 20.0, detail: "Q4")

    assert_equal 3, rs.segments.size
    assert rs.overflowed?
    durations = rs.segments.map { |s| s[:duration] }
    # Q2 (5.0) should have been replaced by Q4 (20.0)
    refute_includes durations, 5.0
    assert_includes durations, 20.0
  end

  test "does not replace when new segment is slower than min" do
    rs = Catpm::RequestSegments.new(max_segments: 2)
    rs.add(type: :sql, duration: 10.0, detail: "Q1")
    rs.add(type: :sql, duration: 20.0, detail: "Q2")

    # Add a faster segment — should NOT replace anything
    rs.add(type: :sql, duration: 5.0, detail: "Q3")

    details = rs.segments.map { |s| s[:detail] }
    assert_includes details, "Q1"
    assert_includes details, "Q2"
    refute_includes details, "Q3"
  end

  test "summary stays accurate even when capped" do
    rs = Catpm::RequestSegments.new(max_segments: 2)
    rs.add(type: :sql, duration: 10.0, detail: "Q1")
    rs.add(type: :sql, duration: 20.0, detail: "Q2")
    rs.add(type: :sql, duration: 5.0, detail: "Q3")
    rs.add(type: :view, duration: 8.0, detail: "view1")

    assert_equal 3, rs.summary[:sql_count]
    assert_in_delta 35.0, rs.summary[:sql_duration], 0.01
    assert_equal 1, rs.summary[:view_count]
    assert_in_delta 8.0, rs.summary[:view_duration], 0.01
  end

  test "to_h returns expected structure" do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 5.0, detail: "SELECT 1")

    result = rs.to_h
    assert result.key?(:segments)
    assert result.key?(:segment_summary)
    assert result.key?(:segments_capped)
    assert_equal false, result[:segments_capped]
    assert_equal 1, result[:segments].size
  end

  test "mixed sql and view segments" do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    3.times { |i| rs.add(type: :sql, duration: i + 1.0, detail: "Q#{i}") }
    2.times { |i| rs.add(type: :view, duration: i + 5.0, detail: "V#{i}") }

    assert_equal 5, rs.segments.size
    assert_equal 3, rs.summary[:sql_count]
    assert_equal 2, rs.summary[:view_count]
    assert_in_delta 6.0, rs.summary[:sql_duration], 0.01
    assert_in_delta 11.0, rs.summary[:view_duration], 0.01
  end
end
