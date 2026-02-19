# frozen_string_literal: true

module Catpm
  class EventsController < ApplicationController
    PER_PAGE = 25

    def index
      @range, period, bucket_seconds = helpers.parse_range(params[:range])

      recent_buckets = Catpm::EventBucket.recent(period).to_a

      # Hero metrics
      @total_events = recent_buckets.sum(&:count)
      period_minutes = period.to_f / 60
      @events_per_min = (period_minutes > 0 ? @total_events / period_minutes : 0).round(1)

      # Group by name for table
      grouped = recent_buckets.group_by(&:name)
      @unique_names = grouped.keys.size

      events_list = grouped.map do |name, bs|
        total_count = bs.sum(&:count)

        # Sparkline data for this name
        slots = {}
        bs.each do |b|
          slot_key = (b.bucket_start.to_i / bucket_seconds) * bucket_seconds
          slots[slot_key] = (slots[slot_key] || 0) + b.count
        end
        now_slot = (Time.current.to_i / bucket_seconds) * bucket_seconds
        sparkline = 60.times.map { |i| slots[now_slot - (59 - i) * bucket_seconds] || 0 }

        {
          name: name,
          total_count: total_count,
          sparkline: sparkline,
          last_seen: bs.map(&:bucket_start).max
        }
      end

      # Sort
      @sort = %w[name total_count last_seen].include?(params[:sort]) ? params[:sort] : 'total_count'
      @dir = params[:dir] == 'asc' ? 'asc' : 'desc'
      events_list = events_list.sort_by { |e| e[@sort.to_sym] || '' }
      events_list = events_list.reverse if @dir == 'desc'

      @total_event_names = events_list.size

      # Sparkline times for tooltips
      now_slot = (Time.current.to_i / bucket_seconds) * bucket_seconds
      @sparkline_times = 60.times.map { |i| Time.at(now_slot - (59 - i) * bucket_seconds).strftime('%H:%M') }

      # Pagination
      @page = [ params[:page].to_i, 1 ].max
      @events = events_list.drop((@page - 1) * PER_PAGE).first(PER_PAGE)

      @active_error_count = Catpm::ErrorRecord.unresolved.count
    end

    def show
      @name = params[:name]
      @range, period, bucket_seconds = helpers.parse_range(params[:range])

      recent_buckets = Catpm::EventBucket.by_name(@name).recent(period).to_a

      # Hero metrics
      @total_count = recent_buckets.sum(&:count)
      period_minutes = period.to_f / 60
      @events_per_min = (period_minutes > 0 ? @total_count / period_minutes : 0).round(1)
      @last_seen = recent_buckets.map(&:bucket_start).max

      # Bar chart data
      slots = {}
      recent_buckets.each do |b|
        slot_key = (b.bucket_start.to_i / bucket_seconds) * bucket_seconds
        slots[slot_key] = (slots[slot_key] || 0) + b.count
      end

      now_slot = (Time.current.to_i / bucket_seconds) * bucket_seconds
      @chart_data = 60.times.map { |i| slots[now_slot - (59 - i) * bucket_seconds] || 0 }
      @chart_times = 60.times.map { |i| Time.at(now_slot - (59 - i) * bucket_seconds).strftime('%H:%M') }

      # Recent samples
      @samples = Catpm::EventSample.by_name(@name).order(recorded_at: :desc).limit(Catpm.config.events_max_samples_per_name)

      @active_error_count = Catpm::ErrorRecord.unresolved.count
    end
  end
end
