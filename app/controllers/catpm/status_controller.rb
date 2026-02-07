# frozen_string_literal: true

module Catpm
  class StatusController < ApplicationController
    def index
      buckets = Catpm::Bucket.order(bucket_start: :desc).to_a

      # Aggregate by (kind, target, operation)
      grouped = buckets.group_by { |b| [b.kind, b.target, b.operation] }

      @endpoints = grouped.map do |key, bs|
        kind, target, operation = key
        total_count = bs.sum(&:count)
        {
          kind: kind,
          target: target,
          operation: operation,
          total_count: total_count,
          avg_duration: total_count > 0 ? bs.sum(&:duration_sum) / total_count : 0.0,
          max_duration: bs.map(&:duration_max).max,
          total_failures: bs.sum(&:failure_count),
          last_seen: bs.map(&:bucket_start).max
        }
      end.sort_by { |e| e[:last_seen] }.reverse.first(50)

      @total_requests = buckets.sum(&:count)
      @endpoint_count = grouped.size

      @samples = Catpm::Sample.order(recorded_at: :desc).limit(20)
      @errors = Catpm::ErrorRecord.order(last_occurred_at: :desc).limit(20)
      @stats = Catpm.stats
      @buffer_size = Catpm.buffer&.size || 0
      @buffer_bytes = Catpm.buffer&.current_bytes || 0
    end
  end
end
