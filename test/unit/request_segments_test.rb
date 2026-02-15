# frozen_string_literal: true

require 'test_helper'

class RequestSegmentsTest < ActiveSupport::TestCase
  test 'initializes with empty segments and zero summary' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    assert_equal [], rs.segments
    assert_equal 0, rs.summary[:sql_count]
    assert_equal 0.0, rs.summary[:sql_duration]
    assert_equal 0, rs.summary[:view_count]
    assert_equal 0.0, rs.summary[:view_duration]
    assert_not rs.overflowed?
  end

  test 'add appends sql segment and updates summary' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 12.345, detail: 'SELECT * FROM users')

    assert_equal 1, rs.segments.size
    seg = rs.segments.first
    assert_equal 'sql', seg[:type]
    assert_equal 12.35, seg[:duration]
    assert_equal 'SELECT * FROM users', seg[:detail]
    assert_nil seg[:source]

    assert_equal 1, rs.summary[:sql_count]
    assert_in_delta 12.345, rs.summary[:sql_duration], 0.01
  end

  test 'add appends view segment and updates summary' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :view, duration: 8.3, detail: 'app/views/users/index.html.erb')

    assert_equal 1, rs.segments.size
    assert_equal 'view', rs.segments.first[:type]
    assert_equal 1, rs.summary[:view_count]
    assert_in_delta 8.3, rs.summary[:view_duration], 0.01
  end

  test 'add includes source when provided' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 15.0, detail: 'SELECT 1', source: 'app/models/user.rb:42')

    assert_equal 'app/models/user.rb:42', rs.segments.first[:source]
  end

  test 'add omits source key when nil' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 1.0, detail: 'SELECT 1')

    assert_not rs.segments.first.key?(:source)
  end

  test 'caps segments at max and replaces fastest with slower' do
    rs = Catpm::RequestSegments.new(max_segments: 3)
    rs.add(type: :sql, duration: 10.0, detail: 'Q1')
    rs.add(type: :sql, duration: 5.0, detail: 'Q2')
    rs.add(type: :sql, duration: 15.0, detail: 'Q3')

    # At capacity — now add a slower one
    rs.add(type: :sql, duration: 20.0, detail: 'Q4')

    assert_equal 3, rs.segments.size
    assert rs.overflowed?
    durations = rs.segments.map { |s| s[:duration] }
    # Q2 (5.0) should have been replaced by Q4 (20.0)
    assert_not_includes durations, 5.0
    assert_includes durations, 20.0
  end

  test 'does not replace when new segment is slower than min' do
    rs = Catpm::RequestSegments.new(max_segments: 2)
    rs.add(type: :sql, duration: 10.0, detail: 'Q1')
    rs.add(type: :sql, duration: 20.0, detail: 'Q2')

    # Add a faster segment — should NOT replace anything
    rs.add(type: :sql, duration: 5.0, detail: 'Q3')

    details = rs.segments.map { |s| s[:detail] }
    assert_includes details, 'Q1'
    assert_includes details, 'Q2'
    assert_not_includes details, 'Q3'
  end

  test 'summary stays accurate even when capped' do
    rs = Catpm::RequestSegments.new(max_segments: 2)
    rs.add(type: :sql, duration: 10.0, detail: 'Q1')
    rs.add(type: :sql, duration: 20.0, detail: 'Q2')
    rs.add(type: :sql, duration: 5.0, detail: 'Q3')
    rs.add(type: :view, duration: 8.0, detail: 'view1')

    assert_equal 3, rs.summary[:sql_count]
    assert_in_delta 35.0, rs.summary[:sql_duration], 0.01
    assert_equal 1, rs.summary[:view_count]
    assert_in_delta 8.0, rs.summary[:view_duration], 0.01
  end

  test 'to_h returns expected structure' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :sql, duration: 5.0, detail: 'SELECT 1')

    result = rs.to_h
    assert result.key?(:segments)
    assert result.key?(:segment_summary)
    assert result.key?(:segments_capped)
    assert_equal false, result[:segments_capped]
    assert_equal 1, result[:segments].size
  end

  test 'mixed sql and view segments' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    3.times { |i| rs.add(type: :sql, duration: i + 1.0, detail: "Q#{i}") }
    2.times { |i| rs.add(type: :view, duration: i + 5.0, detail: "V#{i}") }

    assert_equal 5, rs.segments.size
    assert_equal 3, rs.summary[:sql_count]
    assert_equal 2, rs.summary[:view_count]
    assert_in_delta 6.0, rs.summary[:sql_duration], 0.01
    assert_in_delta 11.0, rs.summary[:view_duration], 0.01
  end

  test 'add tracks custom segment in summary' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :custom, duration: 25.0, detail: 'fetch_rates')

    assert_equal 1, rs.segments.size
    assert_equal 'custom', rs.segments.first[:type]
    assert_equal 1, rs.summary[:custom_count]
    assert_in_delta 25.0, rs.summary[:custom_duration], 0.01
  end

  test 'add tracks cache segment in summary' do
    rs = Catpm::RequestSegments.new(max_segments: 10)
    rs.add(type: :cache, duration: 0.5, detail: 'cache.read users/1')

    assert_equal 1, rs.segments.size
    assert_equal 'cache', rs.segments.first[:type]
    assert_equal 1, rs.summary[:cache_count]
    assert_in_delta 0.5, rs.summary[:cache_duration], 0.01
  end

  test 'mixed all segment types' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.add(type: :sql, duration: 5.0, detail: 'Q1')
    rs.add(type: :view, duration: 8.0, detail: 'V1')
    rs.add(type: :custom, duration: 20.0, detail: 'api_call')
    rs.add(type: :cache, duration: 0.3, detail: 'cache.read key')

    assert_equal 4, rs.segments.size
    assert_equal 1, rs.summary[:sql_count]
    assert_equal 1, rs.summary[:view_count]
    assert_equal 1, rs.summary[:custom_count]
    assert_equal 1, rs.summary[:cache_count]
  end

  test 'dynamic summary tracks http segments' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.add(type: :http, duration: 340.0, detail: 'GET api.stripe.com/v1/charges (200)')
    rs.add(type: :http, duration: 120.0, detail: 'POST hooks.slack.com/services (200)')

    assert_equal 2, rs.summary[:http_count]
    assert_in_delta 460.0, rs.summary[:http_duration], 0.01
  end

  test 'dynamic summary tracks mailer segments' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.add(type: :mailer, duration: 45.0, detail: 'UserMailer#welcome')

    assert_equal 1, rs.summary[:mailer_count]
    assert_in_delta 45.0, rs.summary[:mailer_duration], 0.01
  end

  test 'dynamic summary tracks storage segments' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.add(type: :storage, duration: 200.0, detail: 'upload avatar.jpg')

    assert_equal 1, rs.summary[:storage_count]
    assert_in_delta 200.0, rs.summary[:storage_duration], 0.01
  end

  test 'dynamic summary returns 0 for unknown types' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    assert_equal 0, rs.summary[:http_count]
    assert_equal 0, rs.summary[:nonexistent_count]
  end

  test 'all segment types mixed in one request' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.add(type: :sql, duration: 5.0, detail: 'Q1')
    rs.add(type: :view, duration: 8.0, detail: 'V1')
    rs.add(type: :cache, duration: 0.3, detail: 'C1')
    rs.add(type: :http, duration: 340.0, detail: 'H1')
    rs.add(type: :mailer, duration: 45.0, detail: 'M1')
    rs.add(type: :storage, duration: 200.0, detail: 'S1')
    rs.add(type: :custom, duration: 20.0, detail: 'X1')

    assert_equal 7, rs.segments.size
    assert_equal 1, rs.summary[:sql_count]
    assert_equal 1, rs.summary[:view_count]
    assert_equal 1, rs.summary[:cache_count]
    assert_equal 1, rs.summary[:http_count]
    assert_equal 1, rs.summary[:mailer_count]
    assert_equal 1, rs.summary[:storage_count]
    assert_equal 1, rs.summary[:custom_count]
  end

  # ─── Span nesting tests ───

  test 'push_span and pop_span create a span segment with duration' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    index = rs.push_span(type: :custom, detail: 'MySpan', started_at: start)
    assert_equal 0, index
    assert_equal 1, rs.segments.size
    assert_nil rs.segments[0][:duration]

    sleep(0.005)
    rs.pop_span(index)

    assert rs.segments[0][:duration] >= 4.0, "Expected duration >= 4ms, got #{rs.segments[0][:duration]}"
    assert_equal 1, rs.summary[:custom_count]
    assert rs.summary[:custom_duration] >= 4.0
  end

  test 'add auto-sets parent_index from span stack' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    parent_idx = rs.push_span(type: :request, detail: 'GET /test', started_at: start)
    rs.add(type: :sql, duration: 5.0, detail: 'SELECT 1', started_at: start)

    assert_equal parent_idx, rs.segments[1][:parent_index]

    rs.pop_span(parent_idx)
  end

  test 'segments without span stack have no parent_index' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.add(type: :sql, duration: 5.0, detail: 'SELECT 1')

    assert_not rs.segments[0].key?(:parent_index)
  end

  test 'nested spans create correct parent chain' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    root = rs.push_span(type: :request, detail: 'GET /', started_at: start)
    child = rs.push_span(type: :custom, detail: 'Service.call', started_at: start)
    rs.add(type: :sql, duration: 2.0, detail: 'INSERT INTO ...', started_at: start)

    # SQL's parent should be the child span
    assert_equal child, rs.segments[2][:parent_index]
    # child span's parent should be root
    assert_equal root, rs.segments[1][:parent_index]
    # root has no parent
    assert_not rs.segments[0].key?(:parent_index)

    rs.pop_span(child)
    rs.pop_span(root)
  end

  test 'push_span returns nil when at capacity' do
    rs = Catpm::RequestSegments.new(max_segments: 2)
    rs.add(type: :sql, duration: 5.0, detail: 'Q1')
    rs.add(type: :sql, duration: 5.0, detail: 'Q2')

    index = rs.push_span(type: :custom, detail: 'Span')
    assert_nil index
    assert_equal 2, rs.segments.size
  end

  test 'pop_span is safe with nil index' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.pop_span(nil) # should not raise
    assert_equal 0, rs.segments.size
  end

  test 'segments added after pop_span have correct parent' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    root = rs.push_span(type: :request, detail: 'GET /', started_at: start)
    child = rs.push_span(type: :custom, detail: 'Inner', started_at: start)
    rs.pop_span(child)

    # After popping child, new segments should be children of root
    rs.add(type: :view, duration: 3.0, detail: 'show.html.erb', started_at: start)
    assert_equal root, rs.segments.last[:parent_index]

    rs.pop_span(root)
  end
end
