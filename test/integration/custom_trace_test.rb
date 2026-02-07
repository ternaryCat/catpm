# frozen_string_literal: true

require "test_helper"

class CustomTraceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure do |c|
      c.enabled = true
      c.error_handler = ->(e) { raise e }
      c.slow_threshold = 50
    end
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
    @flusher = Catpm::Flusher.new(buffer: @buffer, interval: 30, jitter: 0)

    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  teardown do
    Catpm.buffer = nil

    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  test "trace block flows through to database" do
    Catpm.trace("PaymentProcessing", metadata: { provider: "stripe" }) do
      sleep(0.01)
    end

    @flusher.flush_cycle

    assert_equal 1, Catpm::Bucket.count
    bucket = Catpm::Bucket.first
    assert_equal "custom", bucket.kind
    assert_equal "PaymentProcessing", bucket.target
    assert_equal 1, bucket.count
    assert bucket.duration_sum >= 5.0
  end

  test "trace error flows through to database" do
    assert_raises(RuntimeError) do
      Catpm.trace("FailingTask") do
        raise RuntimeError, "task failed"
      end
    end

    @flusher.flush_cycle

    assert_equal 1, Catpm::ErrorRecord.count
    error = Catpm::ErrorRecord.first
    assert_equal "RuntimeError", error.error_class
    assert_equal "task failed", error.message
    assert_equal "custom", error.kind
  end

  test "manual span flows through to database" do
    span = Catpm.start_trace("LongImport", metadata: { file: "users.csv" })
    sleep(0.01)
    span.finish

    @flusher.flush_cycle

    assert_equal 1, Catpm::Bucket.count
    bucket = Catpm::Bucket.first
    assert_equal "custom", bucket.kind
    assert_equal "LongImport", bucket.target
  end
end
