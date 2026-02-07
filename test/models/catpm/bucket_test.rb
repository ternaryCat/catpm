# frozen_string_literal: true

require "test_helper"

module Catpm
  class BucketTest < ActiveSupport::TestCase
    setup do
      @bucket = Bucket.create!(
        kind: "http",
        target: "UsersController#index",
        operation: "GET",
        bucket_start: Time.current.change(sec: 0),
        count: 100,
        success_count: 95,
        failure_count: 5,
        duration_sum: 5000.0,
        duration_max: 250.0,
        duration_min: 10.0
      )
    end

    teardown do
      Bucket.delete_all
    end

    test "creates valid bucket" do
      assert @bucket.persisted?
    end

    test "requires kind, target, bucket_start" do
      bucket = Bucket.new
      refute bucket.valid?
      assert_includes bucket.errors[:kind], "can't be blank"
      assert_includes bucket.errors[:target], "can't be blank"
      assert_includes bucket.errors[:bucket_start], "can't be blank"
    end

    test "unique constraint on kind, target, operation, bucket_start" do
      assert_raises(ActiveRecord::RecordNotUnique) do
        Bucket.create!(
          kind: @bucket.kind,
          target: @bucket.target,
          operation: @bucket.operation,
          bucket_start: @bucket.bucket_start
        )
      end
    end

    test "allows same target with different kind" do
      bucket2 = Bucket.create!(
        kind: "job",
        target: @bucket.target,
        operation: @bucket.operation,
        bucket_start: @bucket.bucket_start
      )
      assert bucket2.persisted?
    end

    test "average_duration" do
      assert_in_delta 50.0, @bucket.average_duration, 0.01
    end

    test "average_duration with zero count" do
      @bucket.update!(count: 0, duration_sum: 0)
      assert_equal 0.0, @bucket.average_duration
    end

    test "failure_rate" do
      assert_in_delta 0.05, @bucket.failure_rate, 0.001
    end

    test "by_kind scope" do
      Bucket.create!(kind: "job", target: "SomeJob", bucket_start: Time.current.change(sec: 0))
      assert_equal 1, Bucket.by_kind("http").count
      assert_equal 1, Bucket.by_kind("job").count
    end

    test "percentile with tdigest" do
      td = Catpm::TDigest.new
      100.times { |i| td.add(i * 10) }
      @bucket.update!(p95_digest: td.serialize)

      p50 = @bucket.percentile(0.5)
      assert_not_nil p50
      assert_in_delta 500, p50, 50
    end

    test "percentile without digest returns nil" do
      assert_nil @bucket.percentile(0.5)
    end

    test "parsed_metadata_sum with hash" do
      @bucket.update!(metadata_sum: { db_runtime: 100.0, view_runtime: 50.0 })
      parsed = @bucket.parsed_metadata_sum
      assert_kind_of Hash, parsed
    end

    test "parsed_metadata_sum with nil" do
      @bucket.update!(metadata_sum: nil)
      assert_equal({}, @bucket.parsed_metadata_sum)
    end

    test "has_many samples with dependent delete_all" do
      sample = Sample.create!(
        bucket: @bucket,
        kind: "http",
        sample_type: "slow",
        recorded_at: Time.current,
        duration: 500.0
      )
      assert_includes @bucket.samples, sample

      @bucket.destroy
      assert_nil Sample.find_by(id: sample.id)
    end
  end
end
