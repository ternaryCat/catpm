# frozen_string_literal: true

require 'test_helper'

class StackSamplerTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.configure do |c|
      c.enabled = true
      c.instrument_stack_sampler = true
      c.stack_sample_interval = 0.005
    end
  end

  test 'clear_samples! frees raw backtrace data' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler = Catpm::StackSampler.new(target_thread: Thread.current, request_start: start)
    sampler.start
    sleep(0.02) # collect a few samples
    sampler.stop

    assert sampler.instance_variable_get(:@samples).size > 0, 'Should have collected samples'

    sampler.clear_samples!
    assert_equal [], sampler.instance_variable_get(:@samples)
  end

  test 'stop releases target thread reference' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler = Catpm::StackSampler.new(target_thread: Thread.current, request_start: start)
    sampler.start

    assert_equal Thread.current, sampler.instance_variable_get(:@target)

    sampler.stop
    assert_nil sampler.instance_variable_get(:@target)
  end

  test 'capture respects HARD_SAMPLE_CAP when config max is nil' do
    Catpm.configure { |c| c.max_stack_samples_per_request = nil }

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler = Catpm::StackSampler.new(target_thread: Thread.current, request_start: start)

    # Manually fill to the cap
    cap = Catpm::StackSampler::HARD_SAMPLE_CAP
    cap.times { |i| sampler.instance_variable_get(:@samples) << [start + i * 0.001, []] }

    # Next capture should be rejected
    sampler.capture(start + cap * 0.001)
    assert_equal cap, sampler.instance_variable_get(:@samples).size
  end

  test 'capture respects config max when lower than HARD_SAMPLE_CAP' do
    Catpm.configure { |c| c.max_stack_samples_per_request = 10 }

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler = Catpm::StackSampler.new(target_thread: Thread.current, request_start: start)

    10.times { |i| sampler.instance_variable_get(:@samples) << [start + i * 0.001, []] }

    sampler.capture(start + 10 * 0.001)
    assert_equal 10, sampler.instance_variable_get(:@samples).size
  end

  test 'capture is safe after stop (target is nil)' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler = Catpm::StackSampler.new(target_thread: Thread.current, request_start: start)
    sampler.start
    sampler.stop

    # Should not raise NoMethodError on nil.backtrace_locations
    assert_nothing_raised { sampler.capture(Process.clock_gettime(Process::CLOCK_MONOTONIC)) }
  end

  test 'to_segments returns results and samples can be cleared after' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler = Catpm::StackSampler.new(target_thread: Thread.current, request_start: start)
    sampler.start
    sleep(0.03)
    sampler.stop

    segments = sampler.to_segments(tracked_ranges: [])
    # segments may or may not have entries depending on app frames
    assert_kind_of Array, segments

    sampler.clear_samples!
    # After clearing, to_segments returns empty (no samples)
    assert_equal [], sampler.to_segments(tracked_ranges: [])
  end

  test 'to_call_tree returns results and samples can be cleared after' do
    Catpm.configure { |c| c.instrument_call_tree = true }

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler = Catpm::StackSampler.new(target_thread: Thread.current, request_start: start, call_tree: true)
    sampler.start
    sleep(0.03)
    sampler.stop

    tree = sampler.to_call_tree(tracked_ranges: [])
    assert_kind_of Array, tree

    sampler.clear_samples!
    assert_equal [], sampler.to_call_tree(tracked_ranges: [])
  end
end
