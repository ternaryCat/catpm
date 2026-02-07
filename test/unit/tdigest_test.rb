# frozen_string_literal: true

require "test_helper"

class TDigestTest < ActiveSupport::TestCase
  test "empty digest" do
    td = Catpm::TDigest.new
    assert td.empty?
    assert_equal 0, td.count
    assert_nil td.percentile(0.5)
  end

  test "single value" do
    td = Catpm::TDigest.new
    td.add(42.0)

    refute td.empty?
    assert_equal 1, td.count
    assert_in_delta 42.0, td.percentile(0.5), 0.01
  end

  test "percentile accuracy for uniform distribution" do
    td = Catpm::TDigest.new
    values = (1..1000).to_a
    values.each { |v| td.add(v) }

    assert_in_delta 500, td.percentile(0.5), 15   # p50 ~ 500
    assert_in_delta 950, td.percentile(0.95), 15   # p95 ~ 950
    assert_in_delta 990, td.percentile(0.99), 15   # p99 ~ 990
  end

  test "percentile accuracy for normal-like distribution" do
    td = Catpm::TDigest.new
    # Simulate a skewed response time distribution
    800.times { td.add(rand(50..200)) }   # Most requests: 50-200ms
    150.times { td.add(rand(200..500)) }  # Some slow: 200-500ms
    50.times  { td.add(rand(500..2000)) } # Few very slow: 500-2000ms

    p50 = td.percentile(0.5)
    p95 = td.percentile(0.95)
    p99 = td.percentile(0.99)

    assert p50 < p95, "p50 (#{p50}) should be less than p95 (#{p95})"
    assert p95 < p99, "p95 (#{p95}) should be less than p99 (#{p99})"
    assert p50 < 300, "p50 (#{p50}) should be under 300ms for this distribution"
  end

  test "percentile boundaries" do
    td = Catpm::TDigest.new
    [10, 20, 30, 40, 50].each { |v| td.add(v) }

    p0 = td.percentile(0.0)
    p100 = td.percentile(1.0)

    assert p0 >= 10, "p0 should be >= min value"
    assert p100 <= 50, "p100 should be <= max value"
  end

  test "merge two digests" do
    td1 = Catpm::TDigest.new
    td2 = Catpm::TDigest.new

    500.times { |i| td1.add(i) }
    500.times { |i| td2.add(500 + i) }

    td1.merge(td2)

    assert_equal 1000, td1.count
    assert_in_delta 500, td1.percentile(0.5), 20
  end

  test "merge with empty digest" do
    td = Catpm::TDigest.new
    td.add(42)

    td.merge(Catpm::TDigest.new)
    assert_equal 1, td.count

    td.merge(nil)
    assert_equal 1, td.count
  end

  test "serialize and deserialize roundtrip" do
    td = Catpm::TDigest.new
    100.times { |i| td.add(i * 10) }

    blob = td.serialize
    assert_kind_of String, blob
    assert blob.encoding == Encoding::ASCII_8BIT

    restored = Catpm::TDigest.deserialize(blob)
    assert_equal td.count, restored.count
    assert_in_delta td.percentile(0.5), restored.percentile(0.5), 1.0
    assert_in_delta td.percentile(0.95), restored.percentile(0.95), 1.0
  end

  test "deserialize nil or empty returns empty digest" do
    assert Catpm::TDigest.deserialize(nil).empty?
    assert Catpm::TDigest.deserialize("").empty?
  end

  test "add returns self for chaining" do
    td = Catpm::TDigest.new
    result = td.add(1)
    assert_same td, result
  end

  test "percentile raises for invalid input" do
    td = Catpm::TDigest.new
    td.add(1)

    assert_raises(ArgumentError) { td.percentile(-0.1) }
    assert_raises(ArgumentError) { td.percentile(1.1) }
  end
end
