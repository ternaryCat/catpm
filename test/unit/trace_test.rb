# frozen_string_literal: true

require "test_helper"

class TraceTest < ActiveSupport::TestCase
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

  test "trace block records custom event" do
    result = Catpm.trace("PaymentProcessing") do
      sleep(0.005)
      42
    end

    assert_equal 42, result
    assert_equal 1, @buffer.size

    ev = @buffer.drain.first
    assert_equal "custom", ev.kind
    assert_equal "PaymentProcessing", ev.target
    assert ev.duration >= 4.0, "Expected duration >= 4ms, got #{ev.duration}"
  end

  test "trace block with metadata" do
    Catpm.trace("TelegramPoller#handle", metadata: { update_type: "message" }) do
      # work
    end

    ev = @buffer.drain.first
    assert_equal({ update_type: "message" }, ev.metadata)
  end

  test "trace block records error and re-raises" do
    assert_raises(RuntimeError) do
      Catpm.trace("FailingTask") do
        raise RuntimeError, "task failed"
      end
    end

    ev = @buffer.drain.first
    assert_equal "FailingTask", ev.target
    assert ev.error?
    assert_equal "RuntimeError", ev.error_class
    assert_equal "task failed", ev.error_message
    assert ev.duration >= 0
  end

  test "trace is no-op when disabled" do
    Catpm.configure { |c| c.enabled = false }

    result = Catpm.trace("Something") { 99 }

    assert_equal 99, result
    assert_equal 0, @buffer.size
  end

  test "trace is no-op when buffer is nil" do
    Catpm.buffer = nil

    result = Catpm.trace("Something") { 99 }

    assert_equal 99, result
  end

  test "start_trace creates a span" do
    span = Catpm.start_trace("LongImport", metadata: { file: "users.csv" })

    assert_instance_of Catpm::Span, span
    refute span.finished?
  end

  test "span finish records custom event" do
    span = Catpm.start_trace("LongImport", metadata: { file: "users.csv" })
    sleep(0.005)
    span.finish

    assert span.finished?
    assert_equal 1, @buffer.size

    ev = @buffer.drain.first
    assert_equal "custom", ev.kind
    assert_equal "LongImport", ev.target
    assert ev.duration >= 4.0
  end

  test "span finish with error records error event" do
    span = Catpm.start_trace("FailingImport")
    error = RuntimeError.new("import failed")
    error.set_backtrace(["app/services/import.rb:10:in `run'"])
    span.finish(error: error)

    ev = @buffer.drain.first
    assert ev.error?
    assert_equal "RuntimeError", ev.error_class
  end

  test "span finish is idempotent" do
    span = Catpm.start_trace("Test")
    span.finish
    span.finish

    assert_equal 1, @buffer.size
  end

  test "span finish is no-op when disabled" do
    Catpm.configure { |c| c.enabled = false }

    span = Catpm.start_trace("Test")
    span.finish

    assert span.finished?
    assert_equal 0, @buffer.size
  end
end
