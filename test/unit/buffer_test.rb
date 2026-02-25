# frozen_string_literal: true

require 'test_helper'

class BufferTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    @buffer = Catpm::Buffer.new(max_bytes: 1024)
  end

  test 'push and drain' do
    event = make_event
    assert_equal :accepted, @buffer.push(event)
    assert_equal 1, @buffer.size
    assert_not @buffer.empty?

    events = @buffer.drain
    assert_equal 1, events.size
    assert_equal event, events.first
    assert @buffer.empty?
    assert_equal 0, @buffer.current_bytes
  end

  test 'drain returns empty array when empty' do
    events = @buffer.drain
    assert_equal [], events
  end

  test 'tracks current_bytes' do
    event = make_event
    bytes_before = @buffer.current_bytes
    @buffer.push(event)
    assert @buffer.current_bytes > bytes_before
  end

  test 'accepts events above max_bytes and signals flush' do
    event = make_event(target: 'A' * 100)
    small_buffer = Catpm::Buffer.new(max_bytes: event.estimated_bytes + 1)

    flush_signaled = false
    small_buffer.on_flush_needed { flush_signaled = true }

    assert_equal :accepted, small_buffer.push(event)
    assert_not flush_signaled

    # Second event exceeds max_bytes but is accepted (triggers flush signal)
    assert_equal :accepted, small_buffer.push(event)
    assert flush_signaled
    assert_equal 2, small_buffer.size
  end

  test 'drops events at hard safety cap (3x max_bytes)' do
    event = make_event(target: 'A' * 100)
    bytes = event.estimated_bytes
    # Buffer where 3 events fit but 4th exceeds 3x cap
    tiny_buffer = Catpm::Buffer.new(max_bytes: bytes + 1)

    # Fill up to ~3x capacity
    3.times { tiny_buffer.push(event) }

    # 4th push should be dropped (exceeds 3x hard cap)
    result = tiny_buffer.push(event)
    assert_equal :dropped, result
    assert_equal 1, tiny_buffer.dropped_count
    assert_equal 1, Catpm.stats[:dropped_events]
  end

  test 'backpressure returns :dropped at hard cap' do
    tiny_buffer = Catpm::Buffer.new(max_bytes: 1) # 1 byte, hard cap = 3 bytes
    event = make_event

    result = tiny_buffer.push(event)
    assert_equal :dropped, result
  end

  test 'thread safety - concurrent pushes' do
    large_buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    threads = 10.times.map do |i|
      Thread.new do
        100.times do |j|
          event = make_event(target: "thread_#{i}_event_#{j}")
          large_buffer.push(event)
        end
      end
    end

    threads.each(&:join)
    events = large_buffer.drain

    assert_equal 1000, events.size
    assert large_buffer.empty?
  end

  test 'thread safety - concurrent push and drain' do
    large_buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    total_drained = Concurrent::AtomicFixnum.new(0)

    writers = 5.times.map do
      Thread.new do
        50.times do
          large_buffer.push(make_event)
          sleep(0.001)
        end
      end
    end

    drainer = Thread.new do
      25.times do
        drained = large_buffer.drain
        total_drained.increment(drained.size)
        sleep(0.01)
      end
    end

    writers.each(&:join)
    drainer.join

    # Drain remaining
    remaining = large_buffer.drain
    total_drained.increment(remaining.size)

    assert_equal 250, total_drained.value
  end

  test 'reset! clears everything' do
    @buffer.push(make_event)
    @buffer.reset!

    assert @buffer.empty?
    assert_equal 0, @buffer.current_bytes
    assert_equal 0, @buffer.dropped_count
  end

  private

  def make_event(target: 'TestController#index')
    Catpm::Event.new(kind: :http, target: target, operation: 'GET', duration: 50.0)
  end
end
