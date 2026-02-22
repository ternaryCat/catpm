# frozen_string_literal: true

module Catpm
  class EndpointsController < ApplicationController
    def show
      @kind = params[:kind]
      @target = params[:target]
      @operation = params[:operation].presence || ''

      # Time range filter
      @range, period, _bucket_seconds = helpers.parse_range(remembered_range, extra_valid: ['all'])

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

      endpoint_samples = Catpm::Sample
        .joins(:bucket)
        .where(catpm_buckets: { kind: @kind, target: @target, operation: @operation })

      if @range != 'all'
        endpoint_samples = endpoint_samples.where('catpm_samples.recorded_at >= ?', period.ago)
      end

      @slow_samples = endpoint_samples.where(sample_type: 'slow').order(duration: :desc).limit(10)
      @samples = endpoint_samples.where(sample_type: 'random').order(recorded_at: :desc).limit(10)
      @error_samples = endpoint_samples.where(sample_type: 'error').order(recorded_at: :desc).limit(10)

      @active_error_count = Catpm::ErrorRecord.unresolved.count
    end

    def destroy
      kind = params[:kind]
      target = params[:target]
      operation = params[:operation].presence || ''

      Catpm::Bucket.where(kind: kind, target: target, operation: operation).destroy_all
      redirect_to catpm.status_index_path, notice: 'Endpoint deleted'
    end
  end
end
