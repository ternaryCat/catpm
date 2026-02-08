# frozen_string_literal: true

require "test_helper"

class SpanHelpersTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
  end

  teardown do
    Thread.current[:catpm_request_segments] = nil
    Catpm.buffer = nil
  end

  test "span_method creates span for instance method inside request" do
    klass = Class.new do
      include Catpm::SpanHelpers

      def process(x)
        x * 2
      end
      span_method :process, "TestService#process"
    end

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = klass.new.process(21)

    assert_equal 42, result
    assert_equal 1, req_segments.segments.size

    seg = req_segments.segments.first
    assert_equal "custom", seg[:type]
    assert_equal "TestService#process", seg[:detail]
    assert seg[:duration] >= 0
  end

  test "span_method falls back to trace outside request" do
    klass = Class.new do
      include Catpm::SpanHelpers

      def work
        "done"
      end
      span_method :work, "Worker#work"
    end

    result = klass.new.work

    assert_equal "done", result
    assert_equal 1, @buffer.size
    assert_equal "Worker#work", @buffer.drain.first.target
  end

  test "span_class_method creates span for class method" do
    klass = Class.new do
      include Catpm::SpanHelpers

      def self.call(x)
        x + 1
      end
      span_class_method :call, "Service.call"
    end

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = klass.call(5)

    assert_equal 6, result
    assert_equal 1, req_segments.segments.size
    assert_equal "Service.call", req_segments.segments.first[:detail]
  end

  test "span_method passes all argument types correctly" do
    klass = Class.new do
      include Catpm::SpanHelpers

      def compute(a, b, mode:, &block)
        block ? block.call(a + b) : a + b
      end
      span_method :compute, "Math#compute"
    end

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = klass.new.compute(1, 2, mode: :fast) { |sum| sum * 10 }

    assert_equal 30, result
  end

  test "span_method nests SQL under the method span" do
    klass = Class.new do
      include Catpm::SpanHelpers

      def load_data(req_segments)
        req_segments.add(type: :sql, duration: 5.0, detail: "SELECT 1")
        "data"
      end
      span_method :load_data, "DataLoader#load_data"
    end

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    klass.new.load_data(req_segments)

    assert_equal 2, req_segments.segments.size

    method_seg = req_segments.segments[0]
    sql_seg = req_segments.segments[1]

    assert_equal "DataLoader#load_data", method_seg[:detail]
    assert_equal "sql", sql_seg[:type]
    assert_equal 0, sql_seg[:parent_index], "SQL should be nested under method span"
  end
end
