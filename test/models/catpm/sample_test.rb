# frozen_string_literal: true

require "test_helper"

module Catpm
  class SampleTest < ActiveSupport::TestCase
    setup do
      @bucket = Bucket.create!(
        kind: "http",
        target: "UsersController#index",
        bucket_start: Time.current.change(sec: 0)
      )
      @sample = Sample.create!(
        bucket: @bucket,
        kind: "http",
        sample_type: "slow",
        recorded_at: Time.current,
        duration: 750.0,
        context: { method: "GET", path: "/users", status: 200 }
      )
    end

    teardown do
      Sample.delete_all
      Bucket.delete_all
    end

    test "creates valid sample" do
      assert @sample.persisted?
    end

    test "belongs to bucket" do
      assert_equal @bucket, @sample.bucket
    end

    test "requires kind, sample_type, recorded_at, duration" do
      sample = Sample.new(bucket: @bucket)
      refute sample.valid?
      assert_includes sample.errors[:kind], "can't be blank"
      assert_includes sample.errors[:sample_type], "can't be blank"
      assert_includes sample.errors[:recorded_at], "can't be blank"
      assert_includes sample.errors[:duration], "can't be blank"
    end

    test "slow scope" do
      Sample.create!(bucket: @bucket, kind: "http", sample_type: "random", recorded_at: Time.current, duration: 50.0)
      assert_equal 1, Sample.slow.count
    end

    test "errors scope" do
      Sample.create!(bucket: @bucket, kind: "http", sample_type: "error", recorded_at: Time.current, duration: 50.0)
      assert_equal 1, Sample.errors.count
    end

    test "by_kind scope" do
      assert_equal 1, Sample.by_kind("http").count
      assert_equal 0, Sample.by_kind("job").count
    end

    test "parsed_context returns hash" do
      parsed = @sample.parsed_context
      assert_kind_of Hash, parsed
    end

    test "parsed_context with nil" do
      @sample.update!(context: nil)
      assert_equal({}, @sample.parsed_context)
    end
  end
end
