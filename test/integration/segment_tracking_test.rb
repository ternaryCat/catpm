# frozen_string_literal: true

require "test_helper"

class SegmentTrackingTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_segments = true
      c.slow_threshold = 0 # 0ms — everything is "slow" so it gets sampled
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
    Thread.current[:catpm_request_segments] = nil
    Catpm.buffer = nil

    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  test "HTTP request captures SQL segments" do
    get "/demo/db_heavy"
    assert_response :success

    @flusher.flush_cycle

    sample = Catpm::Sample.find_by(kind: "http")
    assert_not_nil sample, "Expected a sample to be created"

    ctx = sample.parsed_context
    assert ctx.key?("segments") || ctx.key?(:segments),
      "Expected segments in context, got: #{ctx.keys}"

    segments = ctx["segments"] || ctx[:segments]
    sql_segments = segments.select { |s| s["type"] == "sql" || s[:type] == "sql" }
    assert sql_segments.any?, "Expected at least 1 SQL segment"
  end

  test "segment summary is aggregated into bucket metadata" do
    get "/demo/db_heavy"
    assert_response :success

    @flusher.flush_cycle

    bucket = Catpm::Bucket.find_by(kind: "http")
    assert_not_nil bucket

    metadata = bucket.parsed_metadata_sum
    assert metadata["sql_count"].to_f > 0 || metadata[:sql_count].to_f > 0,
      "Expected sql_count in metadata_sum, got: #{metadata}"
  end

  test "segment tracking disabled produces no segments" do
    Catpm.configure { |c| c.instrument_segments = false }
    Catpm::Subscribers.subscribe!

    get "/demo/fast"
    assert_response :success

    @flusher.flush_cycle

    sample = Catpm::Sample.find_by(kind: "http")
    next unless sample # might not be sampled

    ctx = sample.parsed_context
    segments = ctx["segments"] || ctx[:segments]
    assert_nil segments
  end

  test "thread-local is cleaned up after request" do
    get "/demo/fast"
    assert_response :success

    assert_nil Thread.current[:catpm_request_segments],
      "Expected thread-local to be cleared after request"
  end
end
