# frozen_string_literal: true

require 'test_helper'

class CollectorTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
    # Reset per-endpoint sample counts so test order doesn't affect sampling decisions
    Catpm::Collector.instance_variable_set(:@random_sample_counts, nil)
  end

  teardown do
    Catpm.buffer = nil
  end

  test 'process_action_controller creates http event' do
    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200,
      duration: 42.5, db_runtime: 10.0, view_runtime: 20.0
    )

    Catpm::Collector.process_action_controller(event)

    assert_equal 1, @buffer.size
    ev = @buffer.drain.first
    assert_equal 'http', ev.kind
    assert_equal 'UsersController#index', ev.target
    assert_equal 'GET', ev.operation
    assert_equal 42.5, ev.duration
    assert_equal 200, ev.status
    assert_equal 10.0, ev.metadata[:db_runtime]
    assert_equal 20.0, ev.metadata[:view_runtime]
  end

  test 'process_action_controller captures exceptions' do
    event = mock_ac_event(
      controller: 'UsersController', action: 'create',
      method: 'POST', path: '/users', status: nil,
      duration: 15.0,
      exception: ['RuntimeError', 'boom'],
      exception_object: RuntimeError.new('boom')
    )

    Catpm::Collector.process_action_controller(event)

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal 'RuntimeError', ev.error_class
    assert_equal 'boom', ev.error_message
  end

  test 'process_action_controller skips ignored targets' do
    Catpm.configure { |c| c.ignored_targets = ['HealthController#*'] }

    event = mock_ac_event(
      controller: 'HealthController', action: 'show',
      method: 'GET', path: '/health', status: 200, duration: 1.0
    )

    Catpm::Collector.process_action_controller(event)
    assert_equal 0, @buffer.size
  end

  test 'process_action_controller is no-op when disabled' do
    Catpm.configure { |c| c.enabled = false }

    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200, duration: 10.0
    )

    Catpm::Collector.process_action_controller(event)
    assert_equal 0, @buffer.size
  end

  test 'process_action_controller scrubs PII from context' do
    # Rails' default filter_parameters includes :password
    event = mock_ac_event(
      controller: 'UsersController', action: 'create',
      method: 'POST', path: '/users', status: 200,
      duration: 10.0,
      params: { 'controller' => 'users', 'action' => 'create', 'name' => 'Alice', 'password' => 'secret123' }
    )

    # Reset the cached filter to pick up Rails filter_parameters
    Catpm::Collector.instance_variable_set(:@parameter_filter, nil)
    Catpm::Collector.process_action_controller(event)

    ev = @buffer.drain.first
    params = ev.context[:params] || ev.context['params']
    assert_equal 'Alice', params['name'] || params[:name]
    password_val = params['password'] || params[:password]
    assert_equal '[FILTERED]', password_val
  end

  test 'process_action_controller injects root request segment with parent_index' do
    # Simulate request_start 50ms ago (as if middleware took some time)
    request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.050
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: request_start)
    req_segments.add(type: :sql, duration: 5.0, detail: 'SELECT 1')
    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200, duration: 42.5
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']

    # Root segment injected at index 0 with full request duration (>= 50ms)
    root = segments[0]
    assert_equal 'request', root[:type] || root['type']
    assert_equal 'GET /users', root[:detail] || root['detail']
    root_duration = root[:duration] || root['duration']
    assert root_duration >= 49.0, "Root duration #{root_duration}ms should be >= 49ms (includes middleware time)"

    # SQL segment shifted to index 1 with parent_index pointing to root
    sql = segments[1]
    assert_equal 'sql', sql[:type] || sql['type']
    assert_equal 0, sql[:parent_index] || sql['parent_index']
  end

  test 'process_action_controller nests controller span under root request' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate ControllerSpanSubscriber.start
    ctrl_idx = req_segments.push_span(type: :controller, detail: 'UsersController#index', started_at: start)
    # SQL query inside controller
    req_segments.add(type: :sql, duration: 3.0, detail: 'SELECT * FROM users', started_at: start)
    # Simulate ControllerSpanSubscriber.finish
    req_segments.pop_span(ctrl_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200, duration: 42.5
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']

    # [0] root request (injected, no parent_index)
    # [1] controller "UsersController#index" (was index 0, had no parent -> parent_index: 0)
    # [2] sql "SELECT ..." (was index 1, had parent_index: 0 -> 0+1=1)
    assert_equal 3, segments.size
    assert_equal 'request', segments[0][:type]
    assert_not segments[0].key?(:parent_index)

    assert_equal 'controller', segments[1][:type]
    assert_equal 0, segments[1][:parent_index]

    assert_equal 'sql', segments[2][:type]
    assert_equal 1, segments[2][:parent_index]
  end

  test 'process_action_controller controller span has nonzero duration' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Controller span wrapping a child custom span — pop_span must set duration before collector reads
    ctrl_idx = req_segments.push_span(type: :controller, detail: 'Api::V1::ExpensesController#create', started_at: start)
    sleep(0.005)
    code_idx = req_segments.push_span(type: :custom, detail: 'CreateService#call', started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    sleep(0.005)
    req_segments.pop_span(code_idx)
    req_segments.pop_span(ctrl_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'Api::V1::ExpensesController', action: 'create',
      method: 'POST', path: '/api/v1/expenses', status: 201, duration: 15.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']
    ctrl_seg = segments.find { |s| s[:type] == 'controller' }
    code_seg = segments.find { |s| s[:type] == 'custom' }

    assert ctrl_seg[:duration] > 0, "Controller span must have nonzero duration, got #{ctrl_seg[:duration]}"
    assert ctrl_seg[:duration] >= code_seg[:duration],
      "Controller (#{ctrl_seg[:duration]}ms) must be >= its child custom span (#{code_seg[:duration]}ms)"
  end

  test 'process_action_controller injects middleware segment when gap before controller' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate ControllerSpanSubscriber starting 10ms after request (middleware time)
    sleep(0.01)
    ctrl_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ctrl_idx = req_segments.push_span(type: :controller, detail: 'UsersController#index', started_at: ctrl_start)
    req_segments.add(type: :sql, duration: 3.0, detail: 'SELECT * FROM users', started_at: ctrl_start)
    req_segments.pop_span(ctrl_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200, duration: 50.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']

    # [0] request, [1] middleware, [2] controller, [3] sql
    assert_equal 4, segments.size
    assert_equal 'request', segments[0][:type]
    assert_equal 'middleware', segments[1][:type]
    assert segments[1][:duration] >= 9.0, "Middleware duration should be >= 9ms, got #{segments[1][:duration]}"
    assert_equal 0, segments[1][:parent_index]

    assert_equal 'controller', segments[2][:type]
    assert_equal 0, segments[2][:parent_index]

    assert_equal 'sql', segments[3][:type]
    assert_equal 2, segments[3][:parent_index], 'SQL parent should point to controller (shifted)'

    # Synthetic middleware must appear in segment_summary for Time Breakdown
    summary = ev.context[:segment_summary] || ev.context['segment_summary']
    assert_equal 1, summary[:middleware_count]
    assert summary[:middleware_duration] >= 9.0, "Summary middleware_duration should be >= 9ms, got #{summary[:middleware_duration]}"
  end

  test 'process_action_controller skips synthetic middleware when real middleware segments exist' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate MiddlewareProbe wrapping a middleware (push_span/pop_span)
    sleep(0.005)
    mw_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    mw_idx = req_segments.push_span(type: :middleware, detail: 'ActionDispatch::Executor', started_at: mw_start)

    # Controller starts inside the middleware span
    sleep(0.005)
    ctrl_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ctrl_idx = req_segments.push_span(type: :controller, detail: 'UsersController#index', started_at: ctrl_start)
    req_segments.add(type: :sql, duration: 3.0, detail: 'SELECT * FROM users', started_at: ctrl_start)
    req_segments.pop_span(ctrl_idx)
    req_segments.pop_span(mw_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200, duration: 50.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']

    # Should NOT have a synthetic "Middleware Stack" segment
    synthetic = segments.find { |s| s[:type] == 'middleware' && s[:detail] == 'Middleware Stack' }
    assert_nil synthetic, "Synthetic 'Middleware Stack' should be skipped when real middleware segments exist"

    # Should have real middleware segment
    real_mw = segments.find { |s| s[:type] == 'middleware' && s[:detail] == 'ActionDispatch::Executor' }
    assert real_mw, 'Real middleware segment should be present'

    # Structure: [0] request, [1] middleware:Executor, [2] controller, [3] sql
    assert_equal 'request', segments[0][:type]
    assert_equal 'middleware', segments[1][:type]
    assert_equal 'controller', segments[2][:type]
    assert_equal 'sql', segments[3][:type]
  end

  test 'process_action_controller preserves nested parent_index after root injection' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate Catpm.span("Outer") wrapping a SQL query
    span_idx = req_segments.push_span(type: :custom, detail: 'Outer', started_at: start)
    req_segments.add(type: :sql, duration: 2.0, detail: 'INSERT ...', started_at: start)
    req_segments.pop_span(span_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'UsersController', action: 'create',
      method: 'POST', path: '/users', status: 201, duration: 50.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']

    # [0] root request (no parent_index)
    # [1] custom "Outer" (parent_index: 0, was nil -> set to 0)
    # [2] sql "INSERT" (parent_index: 1, was 0 -> 0+1=1)
    assert_equal 3, segments.size
    assert_equal 'request', segments[0][:type]
    assert_not segments[0].key?(:parent_index)

    assert_equal 'custom', segments[1][:type]
    assert_equal 0, segments[1][:parent_index]

    assert_equal 'sql', segments[2][:type]
    assert_equal 1, segments[2][:parent_index]
  end

  test 'untracked segments are placed in timeline gaps not overlapping tracked segments' do
    Catpm.configure { |c| c.show_untracked_segments = true }
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate: controller span (10ms), with SQL at offset 2-4ms and view at offset 6-8ms
    ctrl_idx = req_segments.push_span(type: :controller, detail: 'UsersController#index', started_at: start)
    req_segments.add(type: :sql, duration: 2.0, detail: 'SELECT', started_at: start + 0.002)
    req_segments.add(type: :view, duration: 2.0, detail: 'index.html', started_at: start + 0.006)
    sleep(0.012)
    req_segments.pop_span(ctrl_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200, duration: 50.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']
    untracked = segments.select { |s| (s[:type] || s['type']) == 'other' }

    # Should have Untracked segments in gaps, not overlapping with SQL/view
    untracked.each do |ut|
      ut_start = (ut[:offset] || ut['offset']).to_f
      ut_end = ut_start + (ut[:duration] || ut['duration']).to_f

      segments.each do |seg|
        next if (seg[:type] || seg['type']) == 'other'
        next if (seg[:type] || seg['type']) == 'controller'
        next if (seg[:type] || seg['type']) == 'request'
        seg_off = seg[:offset] || seg['offset']
        next unless seg_off

        seg_start = seg_off.to_f
        seg_end = seg_start + (seg[:duration] || seg['duration']).to_f

        # Untracked must not overlap with tracked segments
        overlaps = ut_start < seg_end && ut_end > seg_start
        assert_not overlaps,
          "Untracked [#{ut_start.round(2)}..#{ut_end.round(2)}] overlaps with " \
          "#{seg[:type]} [#{seg_start.round(2)}..#{seg_end.round(2)}]"
      end
    end
  end

  test 'process_action_controller collapses near-zero code wrapper around controller span' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate CallTracer pushing a "code" span for a thin dispatch method (e.g. #process)
    code_idx = req_segments.push_span(type: :code, detail: 'Telegram::WebhookController#process', started_at: start)
    # Controller span pushed while code span is still on stack → controller is nested under code
    ctrl_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ctrl_idx = req_segments.push_span(type: :controller, detail: 'Telegram::WebhookController#message', started_at: ctrl_start)
    # Code span popped early (TracePoint :return fires before controller notification finishes)
    req_segments.pop_span(code_idx)
    req_segments.add(type: :sql, duration: 5.0, detail: 'SELECT 1', started_at: ctrl_start)
    sleep(0.01)
    req_segments.pop_span(ctrl_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'Telegram::WebhookController', action: 'message',
      method: 'POST', path: '/telegram/webhook', status: 200, duration: 23.66
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']

    # The near-zero "code" wrapper should be collapsed — no code segments in output
    code_segments = segments.select { |s| s[:type] == 'code' }
    assert_empty code_segments, "Near-zero code wrapper should be collapsed, but found: #{code_segments.inspect}"

    # Controller span should be present and parented under root request
    ctrl_seg = segments.find { |s| s[:type] == 'controller' }
    assert ctrl_seg, 'Controller span should be present'
    assert_equal 0, ctrl_seg[:parent_index], 'Controller should be parented under root request'

    # SQL should be parented under controller
    sql_seg = segments.find { |s| s[:type] == 'sql' }
    assert sql_seg, 'SQL span should be present'
    ctrl_idx_final = segments.index(ctrl_seg)
    assert_equal ctrl_idx_final, sql_seg[:parent_index], 'SQL should be parented under controller'
  end

  test 'process_action_controller preserves code spans with real duration' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate a code span with substantial duration — should NOT be collapsed
    code_idx = req_segments.push_span(type: :code, detail: 'SlowService#call', started_at: start)
    ctrl_idx = req_segments.push_span(type: :controller, detail: 'UsersController#index', started_at: start)
    req_segments.add(type: :sql, duration: 3.0, detail: 'SELECT 1', started_at: start)
    sleep(0.01)
    req_segments.pop_span(ctrl_idx)
    req_segments.pop_span(code_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'UsersController', action: 'index',
      method: 'GET', path: '/users', status: 200, duration: 50.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context['segments']

    # Code span with real duration should be preserved
    code_seg = segments.find { |s| s[:type] == 'code' }
    assert code_seg, 'Code span with real duration should NOT be collapsed'
    assert code_seg[:duration] >= 1.0, "Code span should have substantial duration, got #{code_seg[:duration]}"
  end

  test 'process_action_controller with call_tree and no controller span does not crash' do
    Catpm.configure { |c| c.instrument_call_tree = true }
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(
      max_segments: 50, request_start: start,
      stack_sample: true, call_tree: true
    )
    # Only SQL segments, no controller push_span/pop_span (e.g. webhook handler)
    req_segments.add(type: :sql, duration: 3.0, detail: 'SELECT 1', started_at: start)
    req_segments.stop_sampler
    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: 'Telegram::WebhookController', action: 'message',
      method: 'POST', path: '/telegram/webhook', status: 200, duration: 15.0
    )

    # Should not raise "undefined local variable or method `ctrl_idx'"
    assert_nothing_raised { Catpm::Collector.process_action_controller(event) }
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    assert ev, 'Event should be created'
    segments = ev.context[:segments]
    assert_equal 'request', segments[0][:type]
    sql = segments.find { |s| s[:type] == 'sql' }
    assert sql, 'SQL segment should be present'
  end

  test 'process_tracked with call_tree and no controller span does not crash' do
    Catpm.configure { |c| c.instrument_call_tree = true }
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(
      max_segments: 50, request_start: start,
      stack_sample: true, call_tree: true
    )
    req_segments.add(type: :sql, duration: 2.0, detail: 'INSERT INTO logs', started_at: start)
    req_segments.stop_sampler
    Thread.current[:catpm_request_segments] = req_segments

    # Should not raise "undefined local variable or method `ctrl_idx'"
    assert_nothing_raised do
      Catpm::Collector.process_tracked(
        kind: :custom, target: 'WebhookProcessor',
        operation: 'process', duration: 20.0,
        context: {}, metadata: {}, error: nil,
        req_segments: req_segments
      )
    end
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    assert ev, 'Event should be created'
    segments = ev.context[:segments]
    assert_equal 'request', segments[0][:type]
  end

  test 'process_active_job creates job event' do
    event = mock_job_event(
      job_class: 'SendEmailJob', job_id: 'abc-123',
      queue: 'default', executions: 1, duration: 500.0
    )

    Catpm::Collector.process_active_job(event)

    assert_equal 1, @buffer.size
    ev = @buffer.drain.first
    assert_equal 'job', ev.kind
    assert_equal 'SendEmailJob', ev.target
    assert_equal 'default', ev.operation
    assert_equal 500.0, ev.duration
    assert_equal 'abc-123', ev.context[:job_id]
  end

  test 'process_active_job captures job errors' do
    error = StandardError.new('job failed')
    error.set_backtrace(["app/jobs/send_email_job.rb:10:in `perform'"])

    event = mock_job_event(
      job_class: 'SendEmailJob', job_id: 'abc-123',
      queue: 'default', executions: 2, duration: 100.0,
      exception_object: error
    )

    Catpm::Collector.process_active_job(event)

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal 'StandardError', ev.error_class
    assert_equal 'job failed', ev.error_message
  end

  test 'process_custom creates custom event' do
    Catpm::Collector.process_custom(
      name: 'PaymentProcessing',
      duration: 250.0,
      metadata: { provider: 'stripe' },
      context: { order_id: 42 }
    )

    assert_equal 1, @buffer.size
    ev = @buffer.drain.first
    assert_equal 'custom', ev.kind
    assert_equal 'PaymentProcessing', ev.target
    assert_equal 250.0, ev.duration
    assert_equal({ provider: 'stripe' }, ev.metadata)
  end

  test 'process_custom records errors' do
    error = RuntimeError.new('payment failed')
    error.set_backtrace(["app/services/payment.rb:5:in `charge'"])

    Catpm::Collector.process_custom(
      name: 'PaymentProcessing',
      duration: 50.0,
      error: error
    )

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal 'RuntimeError', ev.error_class
  end

  test 'process_custom skips ignored targets' do
    Catpm.configure { |c| c.ignored_targets = ['HealthCheck'] }

    Catpm::Collector.process_custom(name: 'HealthCheck', duration: 1.0)
    assert_equal 0, @buffer.size
  end

  test 'process_custom is no-op when buffer is nil' do
    Catpm.buffer = nil
    Catpm::Collector.process_custom(name: 'Test', duration: 1.0)
    assert_nil Catpm.buffer
  end

  private

  def mock_ac_event(controller:, action:, method:, path:, status:, duration:,
                    db_runtime: nil, view_runtime: nil, params: nil,
                    exception: nil, exception_object: nil)
    payload = {
      controller: controller,
      action: action,
      method: method,
      path: path,
      status: status,
      db_runtime: db_runtime,
      view_runtime: view_runtime,
      params: params || { 'controller' => controller.underscore.sub('_controller', ''), 'action' => action },
      exception: exception,
      exception_object: exception_object
    }

    MockEvent.new(
      payload: payload,
      duration: duration,
      time: Time.current
    )
  end

  MockEvent = Struct.new(:payload, :duration, :time, keyword_init: true)
  MockJob = Struct.new(:job_id, :queue_name, :executions, keyword_init: true)
  MockClass = Struct.new(:name, keyword_init: true)

  def mock_job_event(job_class:, job_id:, queue:, executions:, duration:, exception_object: nil)
    job = MockJob.new(
      job_id: job_id,
      queue_name: queue,
      executions: executions
    )
    job.define_singleton_method(:class) { MockClass.new(name: job_class) }

    payload = {
      job: job,
      exception_object: exception_object
    }

    MockEvent.new(
      payload: payload,
      duration: duration,
      time: Time.current
    )
  end
end
