# frozen_string_literal: true

require 'test_helper'

# Define test service in the dummy app directory so tp.path passes app_frame?.
# Since the entire project lives under /catpm/, the default app_frame? rejects all paths.
# We write to a temp file under /tmp to avoid the /catpm/ exclusion.
module CallTracerTestHelpers
  TEMP_DIR = File.join(Dir.tmpdir, 'catpm_call_tracer_test')

  def self.source_path
    File.join(TEMP_DIR, 'test_services.rb')
  end

  def self.setup_test_classes!
    return if @setup_done

    FileUtils.mkdir_p(TEMP_DIR)

    File.write(source_path, <<~RUBY)
      module TestCallTracerService
        def self.outer
          inner
        end

        def self.inner
          leaf
        end

        def self.leaf
          42
        end
      end

      class TestCallTracerInstance
        def work
          step_a
          step_b
        end

        private

        def step_a
          "a"
        end

        def step_b
          "b"
        end
      end
    RUBY

    load source_path
    @setup_done = true
  end

  def self.cleanup!
    FileUtils.rm_rf(TEMP_DIR) if Dir.exist?(TEMP_DIR)
  end
end

class CallTracerTest < ActiveSupport::TestCase
  setup do
    CallTracerTestHelpers.setup_test_classes!
    Catpm.reset_config!
    @start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @rs = Catpm::RequestSegments.new(max_segments: 200, request_start: @start)

    # Stub app_frame? to recognize our temp test file
    original_method = Catpm::Fingerprint.method(:app_frame?)
    @original_app_frame = original_method
    test_path = CallTracerTestHelpers.source_path
    Catpm::Fingerprint.define_singleton_method(:app_frame?) do |path|
      return true if path == test_path
      original_method.call(path)
    end
  end

  teardown do
    # Restore original app_frame?
    original = @original_app_frame
    if original
      Catpm::Fingerprint.define_singleton_method(:app_frame?) do |path|
        original.call(path)
      end
    end
  end

  test 'creates spans for app-code class methods' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    TestCallTracerService.outer
    tracer.stop

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    assert code_segments.size >= 3, "Expected at least 3 code segments, got #{code_segments.size}: #{code_segments.map { |s| s[:detail] }}"

    details = code_segments.map { |s| s[:detail] }
    assert details.any? { |d| d.include?('.outer') }, "Expected .outer in #{details}"
    assert details.any? { |d| d.include?('.inner') }, "Expected .inner in #{details}"
    assert details.any? { |d| d.include?('.leaf') }, "Expected .leaf in #{details}"
  end

  test 'class methods use dot notation' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    TestCallTracerService.leaf
    tracer.stop

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    leaf = code_segments.find { |s| s[:detail].include?('leaf') }
    assert leaf, "Expected a leaf segment in #{code_segments.map { |s| s[:detail] }}"
    assert_match(/\.leaf$/, leaf[:detail], 'Expected dot notation for class method')
  end

  test 'instance methods use hash notation' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    TestCallTracerInstance.new.work
    tracer.stop

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    work = code_segments.find { |s| s[:detail].include?('work') }
    assert work, "Expected a work segment in #{code_segments.map { |s| s[:detail] }}"
    assert_match(/#work$/, work[:detail], 'Expected hash notation for instance method')
  end

  test 'correct parent-child nesting' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    TestCallTracerService.outer
    tracer.stop

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    outer = code_segments.find { |s| s[:detail].include?('.outer') }
    inner = code_segments.find { |s| s[:detail].include?('.inner') }
    leaf = code_segments.find { |s| s[:detail].include?('.leaf') }

    assert outer && inner && leaf, 'Expected outer, inner, leaf segments'

    outer_idx = @rs.segments.index(outer)
    inner_idx = @rs.segments.index(inner)

    # inner's parent should be outer
    assert_equal outer_idx, inner[:parent_index], 'inner should be child of outer'
    # leaf's parent should be inner
    assert_equal inner_idx, leaf[:parent_index], 'leaf should be child of inner'
  end

  test 'all spans have duration after stop' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    TestCallTracerService.outer
    tracer.stop

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    assert code_segments.size > 0

    code_segments.each do |seg|
      assert seg[:duration], "Expected duration for segment #{seg[:detail]}"
      assert seg[:duration] >= 0, "Duration should be non-negative for #{seg[:detail]}"
    end
  end

  test 'does not create spans for gem or stdlib code' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    [1, 2, 3].map(&:to_s).join(', ')
    tracer.stop

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    assert_equal 0, code_segments.size, "Should not trace stdlib methods, got: #{code_segments.map { |s| s[:detail] }}"
  end

  test 'handles max_segments gracefully' do
    rs = Catpm::RequestSegments.new(max_segments: 2, request_start: @start)
    rs.add(type: :sql, duration: 5.0, detail: 'Q1')
    rs.add(type: :sql, duration: 5.0, detail: 'Q2')

    tracer = Catpm::CallTracer.new(request_segments: rs)
    tracer.start
    TestCallTracerService.outer
    tracer.stop

    # Should not crash, segments stay at max
    assert_equal 2, rs.segments.size
  end

  test 'stop is safe for repeated calls' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    TestCallTracerService.leaf
    tracer.stop
    tracer.stop # should not raise

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    assert code_segments.size >= 1
  end

  test 'stop without start does not raise' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.stop # should not raise
    assert_equal 0, @rs.segments.size
  end

  test 'updates code_count and code_duration in summary' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    tracer.start
    TestCallTracerService.outer
    tracer.stop

    assert @rs.summary[:code_count] >= 3, 'Expected at least 3 code spans in summary'
    assert @rs.summary[:code_duration] >= 0, 'Expected non-negative code_duration'
  end

  test 'spans have offset relative to request_start' do
    tracer = Catpm::CallTracer.new(request_segments: @rs)
    sleep(0.001) # ensure some offset
    tracer.start
    TestCallTracerService.leaf
    tracer.stop

    code_segments = @rs.segments.select { |s| s[:type] == 'code' }
    assert code_segments.size >= 1

    code_segments.each do |seg|
      assert seg[:offset], "Expected offset for segment #{seg[:detail]}"
      assert seg[:offset] >= 0, 'Offset should be non-negative'
    end
  end
end
