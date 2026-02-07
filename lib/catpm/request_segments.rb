# frozen_string_literal: true

module Catpm
  class RequestSegments
    attr_reader :segments, :summary

    def initialize(max_segments:, request_start: nil)
      @max_segments = max_segments
      @request_start = request_start || Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @segments = []
      @overflow = false
      @summary = {
        sql_count: 0, sql_duration: 0.0,
        view_count: 0, view_duration: 0.0
      }
    end

    def add(type:, duration:, detail:, source: nil, started_at: nil)
      case type
      when :sql
        @summary[:sql_count] += 1
        @summary[:sql_duration] += duration
      when :view
        @summary[:view_count] += 1
        @summary[:view_duration] += duration
      end

      offset = started_at ? ((started_at - @request_start) * 1000.0).round(2) : nil

      segment = { type: type.to_s, duration: duration.round(2), detail: detail }
      segment[:offset] = offset if offset
      segment[:source] = source if source

      if @segments.size < @max_segments
        @segments << segment
      else
        @overflow = true
        min_idx = @segments.each_with_index.min_by { |s, _| s[:duration] }.last
        if duration > @segments[min_idx][:duration]
          @segments[min_idx] = segment
        end
      end
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
