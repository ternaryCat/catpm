# frozen_string_literal: true

module Catpm
  class RequestSegments
    # Pre-computed symbol pairs — each type computed once per process lifetime.
    SUMMARY_KEYS = Hash.new { |h, k| h[k] = [:"#{k}_count", :"#{k}_duration"] }

    attr_reader :segments, :summary, :request_start

    def initialize(max_segments:, request_start: nil, stack_sample: false, call_tree: false)
      @max_segments = max_segments
      @request_start = request_start || Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @segments = []
      @overflow = false
      @summary = Hash.new(0)
      @span_stack = []
      @tracked_ranges = []
      @call_tree = call_tree

      if stack_sample
        @sampler = StackSampler.new(target_thread: Thread.current, request_start: @request_start, call_tree: call_tree)
        @sampler.start
      end
    end

    def add(type:, duration:, detail:, source: nil, started_at: nil)
      type_key = type.to_sym
      count_key, dur_key = SUMMARY_KEYS[type_key]
      @summary[count_key] += 1
      @summary[dur_key] += duration

      offset = started_at ? ((started_at - @request_start) * 1000.0).round(2) : nil

      segment = { type: type.to_s, duration: duration.round(2), detail: detail }
      segment[:offset] = offset if offset
      segment[:source] = source if source
      segment[:parent_index] = @span_stack.last if @span_stack.any?

      # Record time range so sampler can skip already-tracked periods
      if started_at && duration > 0
        @tracked_ranges << [started_at, started_at + duration / 1000.0]
      end

      if @max_segments.nil? || @segments.size < @max_segments
        @segments << segment
      else
        @overflow = true
        min_idx = @segments.each_with_index.min_by { |s, _| s[:duration] || Float::INFINITY }.last
        if duration > (@segments[min_idx][:duration] || Float::INFINITY)
          @segments[min_idx] = segment
        end
      end
    end

    def push_span(type:, detail:, started_at: nil)
      offset = started_at ? ((started_at - @request_start) * 1000.0).round(2) : nil

      segment = { type: type.to_s, detail: detail }
      segment[:offset] = offset if offset
      segment[:parent_index] = @span_stack.last if @span_stack.any?

      return nil if @max_segments && @segments.size >= @max_segments

      index = @segments.size
      @segments << segment
      @span_stack.push(index)
      index
    end

    def pop_span(index)
      return unless index

      # Pop from stack — typically it's the last element (LIFO)
      if @span_stack.last == index
        @span_stack.pop
      else
        @span_stack.delete(index)
      end
      segment = @segments[index]
      return unless segment

      started_at = segment[:offset] ? @request_start + (segment[:offset] / 1000.0) : @request_start
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0
      segment[:duration] = duration.round(2)

      type_key = segment[:type].to_sym
      count_key, dur_key = SUMMARY_KEYS[type_key]
      @summary[count_key] += 1
      @summary[dur_key] += duration
    end

    def stop_sampler
      @sampler&.stop
    end

    def sampler_segments
      return [] if @call_tree # call tree mode produces segments via call_tree_segments
      @sampler&.to_segments(tracked_ranges: @tracked_ranges) || []
    end

    def call_tree_segments
      return [] unless @sampler && @call_tree
      @sampler.to_call_tree(tracked_ranges: @tracked_ranges)
    end

    def overflowed?
      @overflow
    end

    def to_h
      {
        segments: @segments,
        segment_summary: @summary,
        segments_capped: @overflow
      }
    end
  end
end
