# frozen_string_literal: true

require "test_helper"
require "ostruct"

class CollectorTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
  end

  teardown do
    Catpm.buffer = nil
  end

  test "process_action_controller creates http event" do
    event = mock_ac_event(
      controller: "UsersController", action: "index",
      method: "GET", path: "/users", status: 200,
      duration: 42.5, db_runtime: 10.0, view_runtime: 20.0
    )

    Catpm::Collector.process_action_controller(event)

    assert_equal 1, @buffer.size
    ev = @buffer.drain.first
    assert_equal "http", ev.kind
    assert_equal "UsersController#index", ev.target
    assert_equal "GET", ev.operation
    assert_equal 42.5, ev.duration
    assert_equal 200, ev.status
    assert_equal 10.0, ev.metadata[:db_runtime]
    assert_equal 20.0, ev.metadata[:view_runtime]
  end

  test "process_action_controller captures exceptions" do
    event = mock_ac_event(
      controller: "UsersController", action: "create",
      method: "POST", path: "/users", status: nil,
      duration: 15.0,
      exception: ["RuntimeError", "boom"],
      exception_object: RuntimeError.new("boom")
    )

    Catpm::Collector.process_action_controller(event)

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal "RuntimeError", ev.error_class
    assert_equal "boom", ev.error_message
  end

  test "process_action_controller skips ignored targets" do
    Catpm.configure { |c| c.ignored_targets = ["HealthController#*"] }

    event = mock_ac_event(
      controller: "HealthController", action: "show",
      method: "GET", path: "/health", status: 200, duration: 1.0
    )

    Catpm::Collector.process_action_controller(event)
    assert_equal 0, @buffer.size
  end

  test "process_action_controller is no-op when disabled" do
    Catpm.configure { |c| c.enabled = false }

    event = mock_ac_event(
      controller: "UsersController", action: "index",
      method: "GET", path: "/users", status: 200, duration: 10.0
    )

    Catpm::Collector.process_action_controller(event)
    assert_equal 0, @buffer.size
  end

  test "process_action_controller scrubs PII from context" do
    # Rails' default filter_parameters includes :password
    event = mock_ac_event(
      controller: "UsersController", action: "create",
      method: "POST", path: "/users", status: 200,
      duration: 10.0,
      params: { "controller" => "users", "action" => "create", "name" => "Alice", "password" => "secret123" }
    )

    # Reset the cached filter to pick up Rails filter_parameters
    Catpm::Collector.instance_variable_set(:@parameter_filter, nil)
    Catpm::Collector.process_action_controller(event)

    ev = @buffer.drain.first
    params = ev.context[:params] || ev.context["params"]
    assert_equal "Alice", params["name"] || params[:name]
    password_val = params["password"] || params[:password]
    assert_equal "[FILTERED]", password_val
  end

  test "process_action_controller injects root request segment with parent_index" do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    req_segments.add(type: :sql, duration: 5.0, detail: "SELECT 1")
    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: "UsersController", action: "index",
      method: "GET", path: "/users", status: 200, duration: 42.5
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context["segments"]

    # Root segment injected at index 0
    root = segments[0]
    assert_equal "request", root[:type] || root["type"]
    assert_equal "GET /users", root[:detail] || root["detail"]
    assert_in_delta 42.5, (root[:duration] || root["duration"]), 0.01

    # SQL segment shifted to index 1 with parent_index pointing to root
    sql = segments[1]
    assert_equal "sql", sql[:type] || sql["type"]
    assert_equal 0, sql[:parent_index] || sql["parent_index"]
  end

  test "process_action_controller nests controller span under root request" do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate ControllerSpanSubscriber.start
    ctrl_idx = req_segments.push_span(type: :controller, detail: "UsersController#index", started_at: start)
    # SQL query inside controller
    req_segments.add(type: :sql, duration: 3.0, detail: "SELECT * FROM users", started_at: start)
    # Simulate ControllerSpanSubscriber.finish
    req_segments.pop_span(ctrl_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: "UsersController", action: "index",
      method: "GET", path: "/users", status: 200, duration: 42.5
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context["segments"]

    # [0] root request (injected, no parent_index)
    # [1] controller "UsersController#index" (was index 0, had no parent -> parent_index: 0)
    # [2] sql "SELECT ..." (was index 1, had parent_index: 0 -> 0+1=1)
    assert_equal 3, segments.size
    assert_equal "request", segments[0][:type]
    refute segments[0].key?(:parent_index)

    assert_equal "controller", segments[1][:type]
    assert_equal 0, segments[1][:parent_index]

    assert_equal "sql", segments[2][:type]
    assert_equal 1, segments[2][:parent_index]
  end

  test "process_action_controller injects middleware segment when gap before controller" do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate ControllerSpanSubscriber starting 10ms after request (middleware time)
    sleep(0.01)
    ctrl_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ctrl_idx = req_segments.push_span(type: :controller, detail: "UsersController#index", started_at: ctrl_start)
    req_segments.add(type: :sql, duration: 3.0, detail: "SELECT * FROM users", started_at: ctrl_start)
    req_segments.pop_span(ctrl_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: "UsersController", action: "index",
      method: "GET", path: "/users", status: 200, duration: 50.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context["segments"]

    # [0] request, [1] middleware, [2] controller, [3] sql
    assert_equal 4, segments.size
    assert_equal "request", segments[0][:type]
    assert_equal "middleware", segments[1][:type]
    assert segments[1][:duration] >= 9.0, "Middleware duration should be >= 9ms, got #{segments[1][:duration]}"
    assert_equal 0, segments[1][:parent_index]

    assert_equal "controller", segments[2][:type]
    assert_equal 0, segments[2][:parent_index]

    assert_equal "sql", segments[3][:type]
    assert_equal 2, segments[3][:parent_index], "SQL parent should point to controller (shifted)"
  end

  test "process_action_controller preserves nested parent_index after root injection" do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    req_segments = Catpm::RequestSegments.new(max_segments: 50, request_start: start)

    # Simulate Catpm.span("Outer") wrapping a SQL query
    span_idx = req_segments.push_span(type: :custom, detail: "Outer", started_at: start)
    req_segments.add(type: :sql, duration: 2.0, detail: "INSERT ...", started_at: start)
    req_segments.pop_span(span_idx)

    Thread.current[:catpm_request_segments] = req_segments

    event = mock_ac_event(
      controller: "UsersController", action: "create",
      method: "POST", path: "/users", status: 201, duration: 50.0
    )
    Catpm::Collector.process_action_controller(event)
    Thread.current[:catpm_request_segments] = nil

    ev = @buffer.drain.first
    segments = ev.context[:segments] || ev.context["segments"]

    # [0] root request (no parent_index)
    # [1] custom "Outer" (parent_index: 0, was nil -> set to 0)
    # [2] sql "INSERT" (parent_index: 1, was 0 -> 0+1=1)
    assert_equal 3, segments.size
    assert_equal "request", segments[0][:type]
    refute segments[0].key?(:parent_index)

    assert_equal "custom", segments[1][:type]
    assert_equal 0, segments[1][:parent_index]

    assert_equal "sql", segments[2][:type]
    assert_equal 1, segments[2][:parent_index]
  end

  test "process_active_job creates job event" do
    event = mock_job_event(
      job_class: "SendEmailJob", job_id: "abc-123",
      queue: "default", executions: 1, duration: 500.0
    )

    Catpm::Collector.process_active_job(event)

    assert_equal 1, @buffer.size
    ev = @buffer.drain.first
    assert_equal "job", ev.kind
    assert_equal "SendEmailJob", ev.target
    assert_equal "default", ev.operation
    assert_equal 500.0, ev.duration
    assert_equal "abc-123", ev.context[:job_id]
  end

  test "process_active_job captures job errors" do
    error = StandardError.new("job failed")
    error.set_backtrace(["app/jobs/send_email_job.rb:10:in `perform'"])

    event = mock_job_event(
      job_class: "SendEmailJob", job_id: "abc-123",
      queue: "default", executions: 2, duration: 100.0,
      exception_object: error
    )

    Catpm::Collector.process_active_job(event)

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal "StandardError", ev.error_class
    assert_equal "job failed", ev.error_message
  end

  test "process_custom creates custom event" do
    Catpm::Collector.process_custom(
      name: "PaymentProcessing",
      duration: 250.0,
      metadata: { provider: "stripe" },
      context: { order_id: 42 }
    )

    assert_equal 1, @buffer.size
    ev = @buffer.drain.first
    assert_equal "custom", ev.kind
    assert_equal "PaymentProcessing", ev.target
    assert_equal 250.0, ev.duration
    assert_equal({ provider: "stripe" }, ev.metadata)
  end

  test "process_custom records errors" do
    error = RuntimeError.new("payment failed")
    error.set_backtrace(["app/services/payment.rb:5:in `charge'"])

    Catpm::Collector.process_custom(
      name: "PaymentProcessing",
      duration: 50.0,
      error: error
    )

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal "RuntimeError", ev.error_class
  end

  test "process_custom skips ignored targets" do
    Catpm.configure { |c| c.ignored_targets = ["HealthCheck"] }

    Catpm::Collector.process_custom(name: "HealthCheck", duration: 1.0)
    assert_equal 0, @buffer.size
  end

  test "process_custom is no-op when buffer is nil" do
    Catpm.buffer = nil
    Catpm::Collector.process_custom(name: "Test", duration: 1.0)
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
      params: params || { "controller" => controller.underscore.sub("_controller", ""), "action" => action },
      exception: exception,
      exception_object: exception_object
    }

    OpenStruct.new(
      payload: payload,
      duration: duration,
      time: Time.current
    )
  end

  def mock_job_event(job_class:, job_id:, queue:, executions:, duration:, exception_object: nil)
    job = OpenStruct.new(
      job_id: job_id,
      queue_name: queue,
      executions: executions
    )
    # Define class.name on the job mock
    job.define_singleton_method(:class) { OpenStruct.new(name: job_class) }

    payload = {
      job: job,
      exception_object: exception_object
    }

    OpenStruct.new(
      payload: payload,
      duration: duration,
      time: Time.current
    )
  end
end
