# frozen_string_literal: true

module Catpm
  class StatusController < ApplicationController
    PER_PAGE = 25

    def index
      # Time range (parsed first — everything below uses this)
      @range, period, bucket_seconds = helpers.parse_range(remembered_range)

      recent_buckets = Catpm::Bucket.recent(period).to_a

      # Sparkline data
      slots = {}
      recent_buckets.each do |b|
        slot_key = (b.bucket_start.to_i / bucket_seconds) * bucket_seconds
        (slots[slot_key] ||= []) << b
      end

      now_slot = (Time.current.to_i / bucket_seconds) * bucket_seconds

      @sparkline_requests = 60.times.map { |i| bs = slots[now_slot - (59 - i) * bucket_seconds]; bs ? bs.sum(&:count) : 0 }
      @sparkline_errors = 60.times.map { |i| bs = slots[now_slot - (59 - i) * bucket_seconds]; bs ? bs.sum(&:failure_count) : 0 }
      @sparkline_durations = 60.times.map do |i|
        bs = slots[now_slot - (59 - i) * bucket_seconds]
        next 0.0 unless bs
        total = bs.sum(&:count)
        total > 0 ? bs.sum(&:duration_sum) / total : 0.0
      end
      @sparkline_times = 60.times.map { |i| Time.at(now_slot - (59 - i) * bucket_seconds).strftime('%H:%M') }

      recent_count = recent_buckets.sum(&:count)
      recent_failures = recent_buckets.sum(&:failure_count)
      earliest_bucket = recent_buckets.min_by(&:bucket_start)&.bucket_start
      effective_period = earliest_bucket ? [[period, Time.current - earliest_bucket].min, 60].max : period
      period_minutes = effective_period.to_f / 60
      @recent_avg_duration = recent_count > 0 ? (recent_buckets.sum(&:duration_sum) / recent_count).round(1) : 0.0
      @error_rate = recent_count > 0 ? (recent_failures.to_f / recent_count * 100).round(1) : 0.0
      @requests_per_min = (recent_count / period_minutes).round(1)
      @recent_count = recent_count

      # Endpoints — aggregated from the SAME time range as hero metrics
      grouped = recent_buckets.group_by { |b| [b.kind, b.target, b.operation] }

      endpoints = grouped.map do |key, bs|
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
      end

      # Kind filter (URL-based)
      @available_kinds = endpoints.map { |e| e[:kind] }.uniq.sort
      @kind_filter = params[:kind] if params[:kind].present? && @available_kinds.include?(params[:kind])
      endpoints = endpoints.select { |e| e[:kind] == @kind_filter } if @kind_filter

      # Server-side sort
      @sort = %w[target total_count avg_duration max_duration total_failures last_seen].include?(params[:sort]) ? params[:sort] : 'last_seen'
      @dir = params[:dir] == 'asc' ? 'asc' : 'desc'
      endpoints = endpoints.sort_by { |e| e[@sort.to_sym] || '' }
      endpoints = endpoints.reverse if @dir == 'desc'

      @total_endpoint_count = endpoints.size

      # Pagination
      @page = [params[:page].to_i, 1].max
      @endpoints = endpoints.drop((@page - 1) * PER_PAGE).first(PER_PAGE)
      @endpoint_count = @endpoints.size

      @active_error_count = Catpm::ErrorRecord.unresolved.count
    end
  end
end
