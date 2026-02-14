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

  test "build_error_context includes segments, duration, status, and target" do
    segments = [{ type: "sql", duration: 5.0, offset: 0, detail: "SELECT 1" }]
    summary = { sql_count: 1, sql_duration: 5.0 }

    @buffer.push(Catpm::Event.new(
      kind: :http, target: "UsersController#show", operation: "GET",
      duration: 42.5, started_at: Time.current, status: 500,
      error_class: "RuntimeError", error_message: "boom",
      backtrace: ["app/controllers/users_controller.rb:10:in `show'"],
      context: {
        method: "GET", path: "/users/1",
        segments: segments,
        segment_summary: summary,
        segments_capped: false
      }
    ))

    @flusher.flush_cycle

    error = Catpm::ErrorRecord.first
    ctx = error.parsed_contexts.first

    assert_in_delta 42.5, ctx["duration"], 0.01
    assert_equal 500, ctx["status"]
    assert_equal "UsersController#show", ctx["target"]
    assert_equal 1, ctx["segments"].size
    assert_equal "sql", ctx["segments"].first["type"]
    assert_equal({ "sql_count" => 1, "sql_duration" => 5.0 }, ctx["segment_summary"])
    assert_equal false, ctx["segments_capped"]
  end

  test "downsample_buckets merges old 1-minute buckets into 5-minute buckets" do
    # Create five 1-minute buckets with bucket_start > 1 hour ago, all within same 5-min window
    base_time = 2.hours.ago.change(sec: 0)
    # Align base_time to a 5-minute boundary
    base_epoch = base_time.to_i
    aligned_epoch = base_epoch - (base_epoch % 300)
    aligned_base = Time.at(aligned_epoch).utc

    5.times do |i|
      td = Catpm::TDigest.new
      10.times { |j| td.add((i + 1) * 10.0 + j) }

      Catpm::Bucket.create!(
        kind: "http", target: "A#index", operation: "GET",
        bucket_start: aligned_base + (i * 60),
        count: 10, success_count: 9, failure_count: 1,
        duration_sum: 100.0, duration_max: 20.0 + i, duration_min: 5.0 - i,
        metadata_sum: { "db_runtime" => 50.0 }.to_json,
        p95_digest: td.serialize
      )
    end

    assert_equal 5, Catpm::Bucket.count

    @flusher.send(:downsample_buckets)

    # Should merge into 1 or 2 buckets depending on 5-minute alignment
    remaining = Catpm::Bucket.all.to_a
    assert remaining.size < 5, "Expected fewer buckets after downsampling, got #{remaining.size}"

    total_count = remaining.sum(&:count)
    assert_equal 50, total_count

    total_duration = remaining.sum(&:duration_sum)
    assert_in_delta 500.0, total_duration, 0.01

    # Verify metadata was merged additively
    total_db_runtime = remaining.sum { |b| b.parsed_metadata_sum["db_runtime"].to_f }
    assert_in_delta 250.0, total_db_runtime, 0.01

    # Verify TDigest was merged
    remaining.each do |b|
      next unless b.p95_digest
      td = Catpm::TDigest.deserialize(b.p95_digest)
      assert td.count > 0
    end
  end

  test "downsample_buckets skips recent buckets" do
    # Create buckets within the last hour — should NOT be downsampled
    recent_time = 30.minutes.ago.change(sec: 0)
    3.times do |i|
      Catpm::Bucket.create!(
        kind: "http", target: "A#index", operation: "GET",
        bucket_start: recent_time + (i * 60),
        count: 5, success_count: 5, failure_count: 0,
        duration_sum: 50.0, duration_max: 15.0, duration_min: 5.0
      )
    end

    assert_equal 3, Catpm::Bucket.count
    @flusher.send(:downsample_buckets)
    assert_equal 3, Catpm::Bucket.count
  end

  test "build_error_context omits segments when not present" do
    @buffer.push(Catpm::Event.new(
      kind: :http, target: "A#error", operation: "GET",
      duration: 50.0, started_at: Time.current,
      error_class: "RuntimeError", error_message: "boom",
      backtrace: ["app/foo.rb:1"],
      context: { path: "/error" }
    ))

    @flusher.flush_cycle

    ctx = Catpm::ErrorRecord.first.parsed_contexts.first
    assert_nil ctx["segments"]
    assert_nil ctx["segment_summary"]
  end
end
