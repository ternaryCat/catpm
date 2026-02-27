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

  # ─── Memory management tests ───

  test 'release! clears all internal state' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(max_segments: 50, request_start: start)
    rs.add(type: :sql, duration: 5.0, detail: 'SELECT 1', started_at: start)
    rs.add(type: :view, duration: 3.0, detail: 'index.html', started_at: start)

    assert_equal 2, rs.segments.size
    assert rs.summary[:sql_count] > 0

    rs.release!

    assert_equal [], rs.segments
    assert_equal({}, rs.summary)
  end

  test 'release! nils out sampler reference' do
    Catpm.configure do |c|
      c.instrument_stack_sampler = true
      c.stack_sample_interval = 0.005
    end

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(
      max_segments: 50, request_start: start, stack_sample: true
    )
    assert_not_nil rs.instance_variable_get(:@sampler)

    rs.stop_sampler
    rs.release!

    assert_nil rs.instance_variable_get(:@sampler)
  end

  test 'sampler_segments clears raw samples after extraction' do
    Catpm.configure do |c|
      c.instrument_stack_sampler = true
      c.stack_sample_interval = 0.005
    end

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(
      max_segments: 50, request_start: start, stack_sample: true
    )
    sleep(0.02)
    rs.stop_sampler

    sampler = rs.instance_variable_get(:@sampler)
    assert sampler.instance_variable_get(:@samples).size > 0, 'Should have samples before extraction'

    rs.sampler_segments
    assert_equal [], sampler.instance_variable_get(:@samples), 'Samples should be cleared after extraction'
  end

  test 'call_tree_segments clears raw samples after extraction' do
    Catpm.configure do |c|
      c.instrument_stack_sampler = true
      c.instrument_call_tree = true
      c.stack_sample_interval = 0.005
    end

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rs = Catpm::RequestSegments.new(
      max_segments: 50, request_start: start,
      stack_sample: true, call_tree: true
    )
    sleep(0.02)
    rs.stop_sampler

    sampler = rs.instance_variable_get(:@sampler)
    assert sampler.instance_variable_get(:@samples).size > 0, 'Should have samples before extraction'

    rs.call_tree_segments
    assert_equal [], sampler.instance_variable_get(:@samples), 'Samples should be cleared after extraction'
  end

  test 'release! is safe to call multiple times' do
    rs = Catpm::RequestSegments.new(max_segments: 50)
    rs.add(type: :sql, duration: 5.0, detail: 'SELECT 1')

    assert_nothing_raised do
      rs.release!
      rs.release!
    end
  end

  # ─── Checkpoint tests ───

  test 'checkpoint triggers when estimated_bytes exceeds memory_limit' do
    # Each segment is ~600 bytes (SEGMENT_BASE_BYTES + strings), use 5000 to allow ~7 segments
    memory_limit = 5_000
    rs = Catpm::RequestSegments.new(max_segments: nil, memory_limit: memory_limit)
    checkpoint_calls = []

    rs.on_checkpoint do |data|
      checkpoint_calls << data
    end

    20.times { |i| rs.add(type: :sql, duration: 1.0 + i, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }

    assert checkpoint_calls.size >= 1, "Expected at least 1 checkpoint, got #{checkpoint_calls.size}"

    checkpoint = checkpoint_calls.first
    assert checkpoint[:segments].is_a?(Array)
    assert checkpoint[:segments].size > 1, 'Checkpoint should contain multiple segments'
    assert checkpoint[:summary].is_a?(Hash)
    assert_equal 0, checkpoint[:checkpoint_number]
  end

  test 'checkpoint increments checkpoint_count' do
    memory_limit = 5_000
    rs = Catpm::RequestSegments.new(max_segments: nil, memory_limit: memory_limit)
    checkpoint_numbers = []

    rs.on_checkpoint do |data|
      checkpoint_numbers << data[:checkpoint_number]
    end

    40.times { |i| rs.add(type: :sql, duration: 1.0, detail: "SELECT * FROM very_long_table_name_#{i} WHERE column = #{i}") }

    assert checkpoint_numbers.size >= 2, "Expected at least 2 checkpoints, got #{checkpoint_numbers.size}"
    assert_equal 0, checkpoint_numbers.first
    assert_equal 1, checkpoint_numbers[1]
    assert_equal checkpoint_numbers.size, rs.checkpoint_count
  end

  test 'checkpoint resets estimated_bytes after firing' do
    memory_limit = 5_000
    rs = Catpm::RequestSegments.new(max_segments: nil, memory_limit: memory_limit)
    bytes_after_checkpoint = nil

    rs.on_checkpoint do |_data|
      bytes_after_checkpoint = rs.estimated_bytes
    end

    20.times { |i| rs.add(type: :sql, duration: 1.0, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }

    assert_not_nil bytes_after_checkpoint, 'Checkpoint should have fired'
    assert_equal 0, bytes_after_checkpoint, 'estimated_bytes should be reset after checkpoint'
  end

  test 'checkpoint preserves open spans in span_stack' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Use a limit that allows several segments but still triggers during the loop
    memory_limit = 5_000
    rs = Catpm::RequestSegments.new(max_segments: nil, memory_limit: memory_limit, request_start: start)
    checkpoint_fired = false

    rs.on_checkpoint { |_| checkpoint_fired = true }

    # Push a span (simulating controller span)
    rs.push_span(type: :controller, detail: 'TestCtrl#action', started_at: start)

    # Add segments until checkpoint
    20.times { |i| rs.add(type: :sql, duration: 1.0, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }

    assert checkpoint_fired, 'Checkpoint should have fired'

    # After checkpoint, the controller span should still be in segments
    ctrl_seg = rs.segments.find { |s| s[:type] == 'controller' }
    assert_not_nil ctrl_seg, 'Controller span should survive checkpoint'
    assert_equal 'TestCtrl#action', ctrl_seg[:detail]

    # New segments should still get the correct parent
    rs.add(type: :sql, duration: 2.0, detail: 'Q', started_at: start)
    last_seg = rs.segments.last
    assert last_seg.key?(:parent_index), 'New segment should have parent_index from span_stack'
  end

  test 'checkpoint resets summary' do
    memory_limit = 5_000
    rs = Catpm::RequestSegments.new(max_segments: nil, memory_limit: memory_limit)
    checkpoint_summaries = []

    rs.on_checkpoint do |data|
      checkpoint_summaries << data[:summary].dup
    end

    20.times { |i| rs.add(type: :sql, duration: 1.0, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }

    assert checkpoint_summaries.size >= 1
    # The first checkpoint should have captured SQL counts
    assert checkpoint_summaries.first[:sql_count] > 1, 'First checkpoint should have multiple SQL counts'

    # After checkpoint, summary should be reset — new segments start fresh
    rs.add(type: :view, duration: 5.0, detail: 'V')
    assert_equal 1, rs.summary[:view_count]
    # SQL count should only reflect post-checkpoint segments (fewer than the batch in checkpoint)
    assert rs.summary[:sql_count] < checkpoint_summaries.first[:sql_count]
  end

  test 'no checkpoint fires without callback' do
    rs = Catpm::RequestSegments.new(max_segments: nil, memory_limit: 5_000)

    assert_nothing_raised do
      20.times { |i| rs.add(type: :sql, duration: 1.0, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }
    end

    assert_equal 0, rs.checkpoint_count
  end

  test 'no checkpoint fires without memory_limit' do
    rs = Catpm::RequestSegments.new(max_segments: nil, memory_limit: nil)
    checkpoint_fired = false
    rs.on_checkpoint { |_| checkpoint_fired = true }

    20.times { |i| rs.add(type: :sql, duration: 1.0, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }

    assert_not checkpoint_fired, 'Checkpoint should not fire when memory_limit is nil'
    assert_equal 0, rs.checkpoint_count
  end

  test 'estimated_bytes increases with each segment' do
    rs = Catpm::RequestSegments.new(max_segments: nil)
    assert_equal 0, rs.estimated_bytes

    rs.add(type: :sql, duration: 5.0, detail: 'SELECT 1')
    first_bytes = rs.estimated_bytes
    assert first_bytes > 0

    rs.add(type: :sql, duration: 3.0, detail: 'SELECT 2')
    assert rs.estimated_bytes > first_bytes
  end

  test 'release! resets estimated_bytes' do
    rs = Catpm::RequestSegments.new(max_segments: nil)
    rs.add(type: :sql, duration: 5.0, detail: 'SELECT 1')
    assert rs.estimated_bytes > 0

    rs.release!
    assert_equal 0, rs.estimated_bytes
  end
end
