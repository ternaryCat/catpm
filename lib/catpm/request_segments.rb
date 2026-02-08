# frozen_string_literal: true

module Catpm
  class RequestSegments
    attr_reader :segments, :summary

    def initialize(max_segments:, request_start: nil)
      @max_segments = max_segments
      @request_start = request_start || Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @segments = []
      @overflow = false
      @summary = Hash.new(0)
      @span_stack = []
    end

    def add(type:, duration:, detail:, source: nil, started_at: nil)
      type_key = type.to_sym
      @summary[:"#{type_key}_count"] += 1
      @summary[:"#{type_key}_duration"] += duration

      offset = started_at ? ((started_at - @request_start) * 1000.0).round(2) : nil

      segment = { type: type.to_s, duration: duration.round(2), detail: detail }
      segment[:offset] = offset if offset
      segment[:source] = source if source
      segment[:parent_index] = @span_stack.last if @span_stack.any?

      if @segments.size < @max_segments
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

      return nil if @segments.size >= @max_segments

      index = @segments.size
      @segments << segment
      @span_stack.push(index)
      index
    end

    def pop_span(index)
      return unless index

      @span_stack.delete(index)
      segment = @segments[index]
      return unless segment

      started_at = segment[:offset] ? @request_start + (segment[:offset] / 1000.0) : @request_start
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0
      segment[:duration] = duration.round(2)

      type_key = segment[:type].to_sym
      @summary[:"#{type_key}_count"] += 1
      @summary[:"#{type_key}_duration"] += duration
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
