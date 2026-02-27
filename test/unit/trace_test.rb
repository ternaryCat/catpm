# frozen_string_literal: true

require 'test_helper'

class TraceTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
  end

  teardown do
    Thread.current[:catpm_request_segments] = nil
    Catpm.buffer = nil
  end

  # ─── Outside request (standalone event) ───

  test 'trace block records custom event when outside request' do
    result = Catpm.trace('PaymentProcessing') do
      sleep(0.005)
      42
    end

    assert_equal 42, result
    assert_equal 1, @buffer.size

    ev = @buffer.drain.first
    assert_equal 'custom', ev.kind
    assert_equal 'PaymentProcessing', ev.target
    assert ev.duration >= 4.0, "Expected duration >= 4ms, got #{ev.duration}"
  end

  test 'trace block with metadata outside request' do
    Catpm.trace('TelegramPoller#handle', metadata: { update_type: 'message' }) do
      # work
    end

    ev = @buffer.drain.first
    assert_equal({ update_type: 'message' }, ev.metadata)
  end

  test 'trace block records error and re-raises' do
    assert_raises(RuntimeError) do
      Catpm.trace('FailingTask') do
        raise RuntimeError, 'task failed'
      end
    end

    ev = @buffer.drain.first
    assert_equal 'FailingTask', ev.target
    assert ev.error?
    assert_equal 'RuntimeError', ev.error_class
    assert_equal 'task failed', ev.error_message
    assert ev.duration >= 0
  end

  test 'trace is no-op when disabled' do
    Catpm.configure { |c| c.enabled = false }

    result = Catpm.trace('Something') { 99 }

    assert_equal 99, result
    assert_equal 0, @buffer.size
  end

  test 'trace is no-op when buffer is nil' do
    Catpm.buffer = nil

    result = Catpm.trace('Something') { 99 }

    assert_equal 99, result
  end

  # ─── Inside request (adds segment) ───

  test 'trace adds custom segment when inside request' do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = Catpm.trace('fetch_exchange_rates') do
      sleep(0.005)
      'rates'
    end

    assert_equal 'rates', result
    assert_equal 0, @buffer.size, 'Should not create standalone event inside request'
    assert_equal 1, req_segments.segments.size

    seg = req_segments.segments.first
    assert_equal 'custom', seg[:type]
    assert_equal 'fetch_exchange_rates', seg[:detail]
    assert seg[:duration] >= 4.0
    assert_equal 1, req_segments.summary[:custom_count]
    assert req_segments.summary[:custom_duration] >= 4.0
  end

  test 'trace records offset inside request' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)
    Thread.current[:catpm_request_segments] = req_segments

    sleep(0.01)
    Catpm.trace('delayed_work') { 'done' }

    seg = req_segments.segments.first
    assert seg[:offset] >= 9.0, "Expected offset >= 9ms, got #{seg[:offset]}"
  end

  test 'trace re-raises error but still adds segment inside request' do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    assert_raises(RuntimeError) do
      Catpm.trace('FailingWork') { raise 'boom' }
    end

    assert_equal 1, req_segments.segments.size
    assert_equal 'FailingWork', req_segments.segments.first[:detail]
    assert_equal 0, @buffer.size
  end

  # ─── Span API ───

  test 'start_trace creates a span' do
    span = Catpm.start_trace('LongImport', metadata: { file: 'users.csv' })

    assert_instance_of Catpm::Span, span
    assert_not span.finished?
  end

  test 'span finish records custom event outside request' do
    span = Catpm.start_trace('LongImport', metadata: { file: 'users.csv' })
    sleep(0.005)
    span.finish

    assert span.finished?
    assert_equal 1, @buffer.size

    ev = @buffer.drain.first
    assert_equal 'custom', ev.kind
    assert_equal 'LongImport', ev.target
    assert ev.duration >= 4.0
  end

  test 'span finish adds segment inside request' do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    span = Catpm.start_trace('ApiCall')
    sleep(0.005)
    span.finish

    assert span.finished?
    assert_equal 0, @buffer.size
    assert_equal 1, req_segments.segments.size

    seg = req_segments.segments.first
    assert_equal 'custom', seg[:type]
    assert_equal 'ApiCall', seg[:detail]
    assert seg[:duration] >= 4.0
  end

  test 'span finish with error records error event' do
    error = RuntimeError.new('import failed')
    error.set_backtrace(["app/services/import.rb:10:in `run'"])

    span = Catpm.start_trace('FailingImport')
    span.finish(error: error)

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal 'RuntimeError', ev.error_class
  end

  test 'span finish is idempotent' do
    span = Catpm.start_trace('Test')
    span.finish
    span.finish

    assert_equal 1, @buffer.size
  end

  test 'span finish is no-op when disabled' do
    Catpm.configure { |c| c.enabled = false }

    span = Catpm.start_trace('Test')
    span.finish

    assert span.finished?
    assert_equal 0, @buffer.size
  end

  # ─── Catpm.span block API ───

  test 'Catpm.span creates nested segment inside request' do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = Catpm.span('PaymentService.process') do
      sleep(0.005)
      'paid'
    end

    assert_equal 'paid', result
    assert_equal 1, req_segments.segments.size

    seg = req_segments.segments.first
    assert_equal 'custom', seg[:type]
    assert_equal 'PaymentService.process', seg[:detail]
    assert seg[:duration] >= 4.0, "Expected duration >= 4ms, got #{seg[:duration]}"
    assert_equal 0, @buffer.size, 'Should not create standalone event'
  end

  test 'Catpm.span nests child segments under parent' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)
    Thread.current[:catpm_request_segments] = req_segments

    Catpm.span('Outer') do
      req_segments.add(type: :sql, duration: 5.0, detail: 'SELECT 1', started_at: start)
    end

    # Outer span is index 0, SQL is index 1
    assert_equal 2, req_segments.segments.size
    assert_equal 0, req_segments.segments[1][:parent_index]
  end

  test 'Catpm.span falls back to trace outside request' do
    result = Catpm.span('StandaloneWork') do
      sleep(0.005)
      'done'
    end

    assert_equal 'done', result
    assert_equal 1, @buffer.size

    ev = @buffer.drain.first
    assert_equal 'custom', ev.kind
    assert_equal 'StandaloneWork', ev.target
    assert ev.duration >= 4.0
  end

  test 'Catpm.span is no-op when disabled' do
    Catpm.configure { |c| c.enabled = false }

    result = Catpm.span('Nothing') { 42 }

    assert_equal 42, result
    assert_equal 0, @buffer.size
  end

  test 'Catpm.span re-raises errors and still records segment' do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    assert_raises(RuntimeError) do
      Catpm.span('FailingSpan') { raise 'boom' }
    end

    assert_equal 1, req_segments.segments.size
    assert_equal 'FailingSpan', req_segments.segments.first[:detail]
    assert req_segments.segments.first[:duration] >= 0
  end

  # ─── track_request pre-sampling ───

  test 'track_request skips RS creation when not sampled' do
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_segments = true
      c.max_random_samples_per_endpoint = 0
      c.random_sample_rate = 1_000_000 # almost never sample
    end
    Catpm::Collector.reset_sample_counts!

    captured_rs = nil
    Catpm.track_request(kind: :custom, target: 'Worker#run', operation: 'process') do
      captured_rs = Thread.current[:catpm_request_segments]
    end

    assert_nil captured_rs, 'Should not create RS when not sampled'

    events = @buffer.drain
    assert_equal 1, events.size, 'Should still create an event (for count/duration)'
    assert_nil events.first.metadata[:_instrumented], 'Should not be marked as instrumented'
  end

  test 'track_request creates RS during filling phase' do
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_segments = true
      c.max_random_samples_per_endpoint = 5
      c.random_sample_rate = 1_000_000 # after filling, almost never sample
    end
    Catpm::Collector.reset_sample_counts!

    captured_rs = nil
    Catpm.track_request(kind: :custom, target: 'NewEndpoint#run', operation: 'process') do
      captured_rs = Thread.current[:catpm_request_segments]
    end

    assert_not_nil captured_rs, 'Should create RS during filling phase'

    events = @buffer.drain
    ev = events.first
    assert_equal 1, ev.metadata[:_instrumented]
  end

  test 'track_request always creates RS with random_sample_rate=1' do
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_segments = true
      c.random_sample_rate = 1 # always instrument
    end
    Catpm::Collector.reset_sample_counts!

    captured_rs = nil
    Catpm.track_request(kind: :custom, target: 'AlwaysInstrumented#run') do
      captured_rs = Thread.current[:catpm_request_segments]
    end

    assert_not_nil captured_rs, 'Should always create RS when random_sample_rate=1'
  end

  # ─── track_request checkpoint integration ───

  test 'track_request triggers checkpoint for long-running requests' do
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_segments = true
      c.max_segments_per_request = nil
      c.max_request_memory = 5_000 # small limit to trigger checkpoint (~7 segments before flush)
    end

    Catpm.track_request(kind: :custom, target: 'LongTask#run') do
      req_segments = Thread.current[:catpm_request_segments]
      20.times { |i| req_segments.add(type: :sql, duration: 1.0, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }
    end

    events = @buffer.drain
    # Should have at least 1 partial checkpoint + 1 final event
    assert events.size >= 2, "Expected at least 2 events (partial + final), got #{events.size}"

    partial_events = events.select { |e| e.context&.dig(:partial) }
    assert partial_events.size >= 1, 'Expected at least 1 partial checkpoint event'

    partial = partial_events.first
    assert_equal 'custom', partial.kind
    assert_equal 'LongTask#run', partial.target
    assert_equal 'random', partial.sample_type
    assert partial.context[:checkpoint_number] >= 0
    assert partial.context[:segments].is_a?(Array)

    # Final event should also be present
    final_events = events.reject { |e| e.context&.dig(:partial) }
    assert final_events.size >= 1, 'Expected at least 1 final event'
  end

  test 'track_request does not trigger checkpoint with default memory limit' do
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_segments = true
      c.max_segments_per_request = 50
      c.max_request_memory = 2.megabytes
    end

    Catpm.track_request(kind: :custom, target: 'NormalRequest#index') do
      req_segments = Thread.current[:catpm_request_segments]
      5.times { |i| req_segments.add(type: :sql, duration: 1.0, detail: "Q#{i}") }
    end

    events = @buffer.drain
    # Only the final event, no checkpoints
    assert_equal 1, events.size
    assert_nil events.first.context&.dig(:partial)
  end

  test 'track_request does not trigger checkpoint when max_request_memory is nil' do
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_segments = true
      c.max_segments_per_request = nil
      c.max_request_memory = nil
    end

    Catpm.track_request(kind: :custom, target: 'UnlimitedTask#run') do
      req_segments = Thread.current[:catpm_request_segments]
      20.times { |i| req_segments.add(type: :sql, duration: 1.0, detail: "SELECT * FROM table_#{i} WHERE id = #{i}") }
    end

    events = @buffer.drain
    assert_equal 1, events.size, 'Should only have final event, no checkpoints'
  end
end
