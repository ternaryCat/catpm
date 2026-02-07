# frozen_string_literal: true

require "test_helper"

class SQLiteAdapterTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  teardown do
    Catpm::Sample.delete_all
    Catpm::Bucket.delete_all
    Catpm::ErrorRecord.delete_all
  end

  test "adapter resolves to SQLite" do
    Catpm::Adapter.reset!
    assert_equal Catpm::Adapter::SQLite, Catpm::Adapter.current
  end

  test "persist_buckets creates new bucket" do
    bucket_data = [{
      kind: "http",
      target: "UsersController#index",
      operation: "GET",
      bucket_start: Time.current.change(sec: 0),
      count: 10,
      success_count: 9,
      failure_count: 1,
      duration_sum: 500.0,
      duration_max: 100.0,
      duration_min: 10.0,
      metadata_sum: { db_runtime: 200.0 },
      p95_digest: nil
    }]

    Catpm::Adapter::SQLite.persist_buckets(bucket_data)

    assert_equal 1, Catpm::Bucket.count
    bucket = Catpm::Bucket.first
    assert_equal "http", bucket.kind
    assert_equal 10, bucket.count
    assert_equal 500.0, bucket.duration_sum
  end

  test "persist_buckets merges into existing bucket" do
    bucket_start = Time.current.change(sec: 0)
    Catpm::Bucket.create!(
      kind: "http", target: "UsersController#index", operation: "GET",
      bucket_start: bucket_start,
      count: 5, success_count: 4, failure_count: 1,
      duration_sum: 250.0, duration_max: 80.0, duration_min: 20.0,
      metadata_sum: { db_runtime: 100.0 }.to_json
    )

    Catpm::Adapter::SQLite.persist_buckets([{
      kind: "http", target: "UsersController#index", operation: "GET",
      bucket_start: bucket_start,
      count: 10, success_count: 9, failure_count: 1,
      duration_sum: 500.0, duration_max: 120.0, duration_min: 5.0,
      metadata_sum: { db_runtime: 200.0, view_runtime: 50.0 },
      p95_digest: nil
    }])

    assert_equal 1, Catpm::Bucket.count
    bucket = Catpm::Bucket.first
    assert_equal 15, bucket.count
    assert_equal 13, bucket.success_count
    assert_equal 750.0, bucket.duration_sum
    assert_equal 120.0, bucket.duration_max
    assert_equal 5.0, bucket.duration_min

    metadata = bucket.parsed_metadata_sum
    assert_in_delta 300.0, metadata["db_runtime"], 0.01
    assert_in_delta 50.0, metadata["view_runtime"], 0.01
  end

  test "persist_errors creates new error" do
    now = Time.current
    Catpm::Adapter::SQLite.persist_errors([{
      fingerprint: "abc123" + "0" * 58,
      kind: "http",
      error_class: "RuntimeError",
      message: "Something went wrong",
      occurrences_count: 1,
      first_occurred_at: now,
      last_occurred_at: now,
      new_contexts: [{ occurred_at: now.iso8601, backtrace: ["app/foo.rb:1"] }]
    }])

    assert_equal 1, Catpm::ErrorRecord.count
    error = Catpm::ErrorRecord.first
    assert_equal "RuntimeError", error.error_class
    assert_equal 1, error.occurrences_count
  end

  test "persist_errors merges into existing error" do
    now = Time.current
    Catpm::ErrorRecord.create!(
      fingerprint: "abc123" + "0" * 58,
      kind: "http",
      error_class: "RuntimeError",
      message: "Something went wrong",
      occurrences_count: 3,
      first_occurred_at: 1.hour.ago,
      last_occurred_at: 5.minutes.ago,
      contexts: [{ occurred_at: 5.minutes.ago.iso8601 }].to_json
    )

    Catpm::Adapter::SQLite.persist_errors([{
      fingerprint: "abc123" + "0" * 58,
      kind: "http",
      error_class: "RuntimeError",
      message: "Something went wrong",
      occurrences_count: 2,
      first_occurred_at: now,
      last_occurred_at: now,
      new_contexts: [{ occurred_at: now.iso8601 }]
    }])

    assert_equal 1, Catpm::ErrorRecord.count
    error = Catpm::ErrorRecord.first
    assert_equal 5, error.occurrences_count
    assert_equal 2, error.parsed_contexts.size
  end

  test "merge_metadata_sum adds values" do
    result = Catpm::Adapter::SQLite.merge_metadata_sum(
      { "db_runtime" => 100.0 },
      { "db_runtime" => 200.0, "view_runtime" => 50.0 }
    )

    assert_in_delta 300.0, result["db_runtime"], 0.01
    assert_in_delta 50.0, result["view_runtime"], 0.01
  end

  test "merge_metadata_sum handles nil" do
    result = Catpm::Adapter::SQLite.merge_metadata_sum(nil, { "x" => 1.0 })
    assert_in_delta 1.0, result["x"], 0.01
  end

  test "modulo_bucket_sql generates SQLite-compatible SQL" do
    sql = Catpm::Adapter::SQLite.modulo_bucket_sql(60)
    assert_includes sql, "strftime"
    assert_includes sql, "% 60"
  end
end
