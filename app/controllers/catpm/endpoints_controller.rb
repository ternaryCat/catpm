# frozen_string_literal: true

module Catpm
  class EndpointsController < ApplicationController
    def show
      @kind = params[:kind]
      @target = params[:target]
      @operation = params[:operation].presence || ''

      # Time range filter
      @range, period, bucket_seconds = helpers.parse_range(remembered_range)

      scope = Catpm::Bucket
        .where(kind: @kind, target: @target, operation: @operation)

      if @range != 'all'
        scope = scope.where('bucket_start >= ?', period.ago)
      end

      @aggregate = scope.pick(
        'SUM(count)',
        'SUM(duration_sum)',
        'MAX(duration_max)',
        'MIN(duration_min)',
        'SUM(failure_count)',
        'SUM(success_count)',
        'MIN(bucket_start)',
        'MAX(bucket_start)'
      )

      @count, @duration_sum, @duration_max, @duration_min, @failure_count, @success_count =
        @aggregate[0..5].map { |v| v || 0 }
      @first_event_at = @aggregate[6]
      @last_event_at = @aggregate[7]

      @avg_duration = @count > 0 ? @duration_sum / @count : 0.0
      @failure_rate = @count > 0 ? @failure_count.to_f / @count : 0.0

      @buckets = scope.order(bucket_start: :desc)

      # Merge all TDigests for combined percentiles
      @tdigest = @buckets.filter_map(&:tdigest).reduce { |merged, td| merged.merge(td); merged }

      # Aggregate metadata across all buckets
      @metadata = {}
      @buckets.each do |b|
        b.parsed_metadata_sum.each do |k, v|
          @metadata[k] = (@metadata[k] || 0) + (v.is_a?(Numeric) ? v : 0)
        end
      end

      # Chart data — request volume, errors, avg duration
      chart_buckets = scope.order(bucket_start: :asc).to_a
      bucket_seconds = helpers.compute_bucket_seconds(chart_buckets) if @range == 'all'

      if bucket_seconds
        slots_count = {}
        slots_errors = {}
        slots_dur_sum = {}
        slots_dur_count = {}
        chart_buckets.each do |b|
          slot_key = (b.bucket_start.to_i / bucket_seconds) * bucket_seconds
          slots_count[slot_key] = (slots_count[slot_key] || 0) + b.count
          slots_errors[slot_key] = (slots_errors[slot_key] || 0) + b.failure_count
          slots_dur_sum[slot_key] = (slots_dur_sum[slot_key] || 0) + b.duration_sum
          slots_dur_count[slot_key] = (slots_dur_count[slot_key] || 0) + b.count
        end

        now_slot = (Time.current.to_i / bucket_seconds) * bucket_seconds
        @chart_requests = 60.times.map { |i| slots_count[now_slot - (59 - i) * bucket_seconds] || 0 }
        @chart_errors = 60.times.map { |i| slots_errors[now_slot - (59 - i) * bucket_seconds] || 0 }
        @chart_durations = 60.times.map do |i|
          key = now_slot - (59 - i) * bucket_seconds
          c = slots_dur_count[key] || 0
          c > 0 ? (slots_dur_sum[key] / c).round(1) : 0
        end
        @chart_times = 60.times.map { |i| Time.at(now_slot - (59 - i) * bucket_seconds).strftime('%H:%M') }
      end

      endpoint_samples = Catpm::Sample
        .joins(:bucket)
        .where(catpm_buckets: { kind: @kind, target: @target, operation: @operation })

      @slow_samples = endpoint_samples.where(sample_type: 'slow').order(duration: :desc).limit(10)
      @samples = endpoint_samples.where(sample_type: 'random').order(recorded_at: :desc).limit(10)
      @error_samples = endpoint_samples.where(sample_type: 'error').order(recorded_at: :desc).limit(10)

      @pref = Catpm::EndpointPref.find_by(kind: @kind, target: @target, operation: @operation)
      @active_error_count = Catpm::ErrorRecord.unresolved.count
    end

    def destroy
      kind = params[:kind]
      target = params[:target]
      operation = params[:operation].presence || ''

      Catpm::Bucket.where(kind: kind, target: target, operation: operation).destroy_all
      Catpm::EndpointPref.find_by(kind: kind, target: target, operation: operation)&.destroy
      if request.xhr?
        render json: { deleted: true }
      else
        redirect_to catpm.status_index_path, notice: 'Endpoint deleted'
      end
    end

    def toggle_pin
      pref = Catpm::EndpointPref.lookup(params[:kind], params[:target], params[:operation])
      pref.pinned = !pref.pinned
      pref.save!
      if request.xhr?
        render json: { pinned: pref.pinned }
      else
        redirect_back fallback_location: catpm.endpoint_path(kind: params[:kind], target: params[:target], operation: params[:operation])
      end
    end

    def toggle_ignore
      pref = Catpm::EndpointPref.lookup(params[:kind], params[:target], params[:operation])
      pref.ignored = !pref.ignored
      pref.save!
      if request.xhr?
        render json: { ignored: pref.ignored }
      else
        redirect_back fallback_location: catpm.status_index_path
      end
    end

    def ignored
      @range, period, _bucket_seconds = helpers.parse_range(remembered_range)
      ignored_prefs = Catpm::EndpointPref.ignored

      scope = @range == 'all' ? Catpm::Bucket.all : Catpm::Bucket.recent(period)
      grouped = scope.group_by { |b| [b.kind, b.target, b.operation] }

      ignored_keys = ignored_prefs.map { |p| [p.kind, p.target, p.operation] }.to_set

      @ignored_endpoints = ignored_prefs.map do |pref|
        key = [pref.kind, pref.target, pref.operation]
        bs = grouped[key]
        total_count = bs ? bs.sum(&:count) : 0
        {
          kind: pref.kind,
          target: pref.target,
          operation: pref.operation,
          total_count: total_count,
          avg_duration: total_count > 0 ? bs.sum(&:duration_sum) / total_count : 0.0,
          last_seen: bs&.map(&:bucket_start)&.max
        }
      end

      @active_endpoint_count = grouped.keys.count { |k| !ignored_keys.include?(k) }
      @active_error_count = Catpm::ErrorRecord.unresolved.count
    end
  end
end
