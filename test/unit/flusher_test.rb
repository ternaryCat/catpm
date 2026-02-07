# frozen_string_literal: true

require "test_helper"

class FlusherTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    @flusher = Catpm::Flusher.new(buffer: @buffer, interval: 30, jitter: 0)

    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  teardown do
    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  test "flush_cycle persists bucket from events" do
    5.times do
      @buffer.push(Catpm::Event.new(
        kind: :http, target: "UsersController#index", operation: "GET",
        duration: 50.0, started_at: Time.current,
        metadata: { db_runtime: 10.0 }
      ))
    end

    @flusher.flush_cycle

    assert_equal 1, Catpm::Bucket.count
    bucket = Catpm::Bucket.first
    assert_equal "http", bucket.kind
    assert_equal "UsersController#index", bucket.target
    assert_equal "GET", bucket.operation
    assert_equal 5, bucket.count
    assert_equal 5, bucket.success_count
    assert_equal 0, bucket.failure_count
    assert_in_delta 250.0, bucket.duration_sum, 0.01
    assert_in_delta 50.0, bucket.duration_max, 0.01
    assert_in_delta 50.0, bucket.duration_min, 0.01
    assert_equal 1, Catpm.stats[:flushes]
  end

  test "flush_cycle groups by kind, target, operation, bucket_start" do
    now = Time.current.change(sec: 0)
    @buffer.push(Catpm::Event.new(kind: :http, target: "A#index", operation: "GET", duration: 10.0, started_at: now))
    @buffer.push(Catpm::Event.new(kind: :http, target: "A#index", operation: "POST", duration: 20.0, started_at: now))
    @buffer.push(Catpm::Event.new(kind: :job, target: "SomeJob", operation: "default", duration: 100.0, started_at: now))

    @flusher.flush_cycle

    assert_equal 3, Catpm::Bucket.count
  end

  test "flush_cycle records slow samples" do
    Catpm.configure { |c| c.slow_threshold = 100 }

    @buffer.push(Catpm::Event.new(
      kind: :http, target: "A#slow", operation: "GET",
      duration: 500.0, started_at: Time.current,
      context: { path: "/slow" }
    ))

    @flusher.flush_cycle

    assert_equal 1, Catpm::Sample.count
    sample = Catpm::Sample.first
    assert_equal "slow", sample.sample_type
    assert_equal 500.0, sample.duration
  end

  test "flush_cycle records error events" do
    @buffer.push(Catpm::Event.new(
      kind: :http, target: "A#error", operation: "GET",
      duration: 50.0, started_at: Time.current,
      error_class: "RuntimeError",
      error_message: "boom",
      backtrace: ["app/controllers/a_controller.rb:10:in `error'"],
      context: { path: "/error" }
    ))

    @flusher.flush_cycle

    assert_equal 1, Catpm::ErrorRecord.count
    error = Catpm::ErrorRecord.first
    assert_equal "RuntimeError", error.error_class
    assert_equal "boom", error.message
    assert_equal 1, error.occurrences_count
    assert_equal "http", error.kind

    # Also check failure count in bucket
    bucket = Catpm::Bucket.first
    assert_equal 1, bucket.failure_count
  end

  test "flush_cycle groups duplicate errors by fingerprint" do
    2.times do
      @buffer.push(Catpm::Event.new(
        kind: :http, target: "A#error", operation: "GET",
        duration: 50.0, started_at: Time.current,
        error_class: "RuntimeError", error_message: "boom",
        backtrace: ["app/controllers/a_controller.rb:10:in `error'"]
      ))
    end

    @flusher.flush_cycle

    assert_equal 1, Catpm::ErrorRecord.count
    assert_equal 2, Catpm::ErrorRecord.first.occurrences_count
  end

  test "flush_cycle builds tdigest" do
    10.times do |i|
      @buffer.push(Catpm::Event.new(
        kind: :http, target: "A#index", operation: "GET",
        duration: (i + 1) * 10.0, started_at: Time.current
      ))
    end

    @flusher.flush_cycle

    bucket = Catpm::Bucket.first
    assert_not_nil bucket.p95_digest

    td = Catpm::TDigest.deserialize(bucket.p95_digest)
    assert_equal 10, td.count
    p50 = td.percentile(0.5)
    assert p50 > 0
  end

  test "flush_cycle is no-op when buffer is empty" do
    @flusher.flush_cycle
    assert_equal 0, Catpm::Bucket.count
  end

  test "flush_cycle respects circuit breaker" do
    # Open the circuit breaker
    5.times { @flusher.instance_variable_get(:@circuit).record_failure }

    @buffer.push(Catpm::Event.new(
      kind: :http, target: "A#index", operation: "GET",
      duration: 50.0, started_at: Time.current
    ))

    @flusher.flush_cycle

    # Events should still be in buffer (not drained) because circuit is open
    # Actually, flush_cycle returns early before draining
    assert_equal 0, Catpm::Bucket.count
  end

  test "multiple flush cycles accumulate bucket data" do
    now = Time.current.change(sec: 0)

    @buffer.push(Catpm::Event.new(
      kind: :http, target: "A#index", operation: "GET",
      duration: 50.0, started_at: now,
      metadata: { db_runtime: 10.0 }
    ))
    @flusher.flush_cycle

    @buffer.push(Catpm::Event.new(
      kind: :http, target: "A#index", operation: "GET",
      duration: 100.0, started_at: now,
      metadata: { db_runtime: 20.0 }
    ))
    @flusher.flush_cycle

    assert_equal 1, Catpm::Bucket.count
    bucket = Catpm::Bucket.first
    assert_equal 2, bucket.count
    assert_in_delta 150.0, bucket.duration_sum, 0.01
    assert_in_delta 100.0, bucket.duration_max, 0.01
    assert_in_delta 50.0, bucket.duration_min, 0.01

    metadata = bucket.parsed_metadata_sum
    assert_in_delta 30.0, metadata["db_runtime"], 0.01
  end
end
