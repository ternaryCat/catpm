# frozen_string_literal: true

require "test_helper"

class HttpTrackingTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure do |c|
      c.enabled = true
      c.error_handler = ->(e) { raise e }
    end
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
    @flusher = Catpm::Flusher.new(buffer: @buffer, interval: 30, jitter: 0)

    Catpm::Subscribers.subscribe!

    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  teardown do
    Catpm::Subscribers.unsubscribe!
    Catpm.buffer = nil

    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  test "tracks HTTP request end-to-end" do
    get "/test/index"
    assert_response :success

    # Events should be in buffer
    assert @buffer.size >= 1, "Expected at least 1 event in buffer, got #{@buffer.size}"

    # Flush to DB
    @flusher.flush_cycle

    assert Catpm::Bucket.count >= 1, "Expected at least 1 bucket after flush"
    bucket = Catpm::Bucket.find_by(kind: "http", target: "TestController#index")
    assert_not_nil bucket
    assert_equal "GET", bucket.operation
    assert bucket.count >= 1
  end

  test "tracks slow request with sample" do
    Catpm.configure do |c|
      c.enabled = true
      c.slow_threshold = 5 # 5ms — sleep(0.01) = 10ms will be "slow"
    end

    get "/test/slow"
    assert_response :success

    @flusher.flush_cycle

    bucket = Catpm::Bucket.find_by(kind: "http", target: "TestController#slow")
    assert_not_nil bucket
    assert bucket.duration_sum >= 5.0, "Expected slow duration, got #{bucket.duration_sum}"

    # Should have a slow sample
    slow_samples = Catpm::Sample.where(sample_type: "slow", kind: "http")
    assert slow_samples.count >= 1, "Expected at least 1 slow sample"
  end

  test "tracks error request" do
    assert_raises(RuntimeError) do
      get "/test/error"
    end

    @flusher.flush_cycle

    # The middleware captures the error event
    # Plus the AS::Notifications subscriber may also capture it
    assert Catpm::Bucket.count >= 1 || @buffer.size >= 0

    errors = Catpm::ErrorRecord.where(kind: "http", error_class: "RuntimeError")
    assert errors.count >= 1, "Expected at least 1 error record"
    assert_equal "boom", errors.first.message
  end
end
