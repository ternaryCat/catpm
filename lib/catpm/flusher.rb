# frozen_string_literal: true

require "concurrent"

module Catpm
  class Flusher
    CLEANUP_INTERVAL = 1.hour
    RANDOM_SAMPLE_RATE = 20 # 1 in N
    MAX_RANDOM_SAMPLES_PER_ENDPOINT = 5
    MAX_SLOW_SAMPLES_PER_ENDPOINT = 5

    attr_reader :running

    def initialize(buffer:, interval: nil, jitter: nil)
      @buffer = buffer
      @interval = interval || Catpm.config.flush_interval
      @jitter = jitter || Catpm.config.flush_jitter
      @circuit = CircuitBreaker.new
      @last_cleanup_at = Time.now
      @running = false
      @timer = nil
    end

    def start
      return if @running

      @running = true
      @timer = Concurrent::TimerTask.new(
        execution_interval: effective_interval,
        run_now: false
      ) { flush_cycle }
      @timer.execute
    end

    def stop(timeout: 5)
      return unless @running

      @running = false
      @timer&.shutdown
      @timer&.wait_for_termination(timeout)
      flush_cycle # Final flush
    end

    # Public for testing and emergency flush
    def flush_cycle
      return if @circuit.open?

      events = @buffer.drain
      return if events.empty?

      buckets, samples, errors = aggregate(events)

      ActiveRecord::Base.connection_pool.with_connection do
        adapter = Catpm::Adapter.current
        adapter.persist_buckets(buckets)

        bucket_map = build_bucket_map(buckets)
        samples = rotate_samples(samples)
        adapter.persist_samples(samples, bucket_map)
        adapter.persist_errors(errors)
      end

      @circuit.record_success
      Catpm.stats[:flushes] += 1

      maybe_cleanup
    rescue => e
      @circuit.record_failure
      Catpm.config.error_handler.call(e)
    end

    def reset!
      @circuit.reset!
      @last_cleanup_at = Time.now
    end

    private

    def effective_interval
      @interval + rand(-@jitter..@jitter)
    end

    def aggregate(events)
      bucket_groups = {}
      samples = []
      error_groups = {}

      # Pre-load existing random sample counts per endpoint for filling phase
      @random_sample_counts = {}
      Catpm::Sample.where(sample_type: "random")
        .joins(:bucket)
        .group("catpm_buckets.kind", "catpm_buckets.target", "catpm_buckets.operation")
        .count
        .each { |(kind, target, op), cnt| @random_sample_counts[[kind, target, op]] = cnt }

      events.each do |event|
        # Bucket aggregation
        key = [event.kind, event.target, event.operation, event.bucket_start]
        bucket = bucket_groups[key] ||= new_bucket_hash(event)

        bucket[:count] += 1
        if event.success?
          bucket[:success_count] += 1
        else
          bucket[:failure_count] += 1
        end
        bucket[:duration_sum] += event.duration
        bucket[:duration_max] = [bucket[:duration_max], event.duration].max
        bucket[:duration_min] = [bucket[:duration_min], event.duration].min

        # Merge metadata
        event.metadata.each do |k, v|
          str_key = k.to_s
          bucket[:metadata_sum][str_key] = (bucket[:metadata_sum][str_key] || 0).to_f + v.to_f
        end

        # TDigest
        bucket[:tdigest].add(event.duration)

        # Collect samples
        sample_type = determine_sample_type(event)
        if sample_type
          samples << {
            bucket_key: key,
            kind: event.kind,
            sample_type: sample_type,
            recorded_at: event.started_at,
            duration: event.duration,
            context: event.context
          }
        end

        # Error grouping
        if event.error?
          fp = Catpm::Fingerprint.generate(
            kind: event.kind,
            error_class: event.error_class,
            backtrace: event.backtrace
          )

          error = error_groups[fp] ||= {
            fingerprint: fp,
            kind: event.kind,
            error_class: event.error_class,
            message: event.error_message,
            occurrences_count: 0,
            first_occurred_at: event.started_at,
            last_occurred_at: event.started_at,
            new_contexts: []
          }

          error[:occurrences_count] += 1
          error[:last_occurred_at] = [error[:last_occurred_at], event.started_at].max

          if error[:new_contexts].size < Catpm.config.max_error_contexts
            error[:new_contexts] << build_error_context(event)
          end
        end
      end

      # Serialize TDigest blobs
      buckets = bucket_groups.values.map do |b|
        b[:p95_digest] = b[:tdigest].empty? ? nil : b[:tdigest].serialize
        b.delete(:tdigest)
        b
      end

      [buckets, samples, error_groups.values]
    end

    def new_bucket_hash(event)
      {
        kind: event.kind,
        target: event.target,
        operation: event.operation,
        bucket_start: event.bucket_start,
        count: 0,
        success_count: 0,
        failure_count: 0,
        duration_sum: 0.0,
        duration_max: 0.0,
        duration_min: Float::INFINITY,
        metadata_sum: {},
        tdigest: TDigest.new
      }
    end

    def determine_sample_type(event)
      return "error" if event.error?

      threshold = Catpm.config.slow_threshold_for(event.kind.to_sym)
      return "slow" if event.duration >= threshold

      # Always sample if endpoint has few random samples (filling phase)
      endpoint_key = [event.kind, event.target, event.operation]
      existing_random = @random_sample_counts[endpoint_key] || 0
      if existing_random < MAX_RANDOM_SAMPLES_PER_ENDPOINT
        @random_sample_counts[endpoint_key] = existing_random + 1
        return "random"
      end

      return "random" if rand(RANDOM_SAMPLE_RATE) == 0

      nil
    end

    def rotate_samples(samples)
      samples.each do |sample|
        kind, target, operation = sample[:bucket_key][0], sample[:bucket_key][1], sample[:bucket_key][2]
        endpoint_samples = Catpm::Sample
          .joins(:bucket)
          .where(catpm_buckets: { kind: kind, target: target, operation: operation })

        case sample[:sample_type]
        when "random"
          existing = endpoint_samples.where(sample_type: "random")
          if existing.count >= MAX_RANDOM_SAMPLES_PER_ENDPOINT
            existing.order(recorded_at: :asc).first.destroy
          end
        when "slow"
          existing = endpoint_samples.where(sample_type: "slow")
          if existing.count >= MAX_SLOW_SAMPLES_PER_ENDPOINT
            weakest = existing.order(duration: :asc).first
            if sample[:duration] > weakest.duration
              weakest.destroy
            else
              sample[:_skip] = true
            end
          end
        end
      end

      samples.reject { |s| s.delete(:_skip) }
    end

    def build_error_context(event)
      ctx = {
        occurred_at: event.started_at.iso8601,
        kind: event.kind,
        operation: event.context.slice(:method, :path, :params, :job_class, :job_id, :queue, :target, :metadata),
        backtrace: (event.backtrace || []).first(10),
        duration: event.duration,
        status: event.status
      }

      ctx[:target] = event.target if event.target.present?

      if event.context[:segments]
        ctx[:segments] = event.context[:segments]
        ctx[:segments_capped] = event.context[:segments_capped]
      end

      if event.context[:segment_summary]
        ctx[:segment_summary] = event.context[:segment_summary]
      end

      ctx
    end

    def build_bucket_map(aggregated_buckets)
      map = {}
      aggregated_buckets.each do |b|
        key = [b[:kind], b[:target], b[:operation], b[:bucket_start]]
        map[key] = Catpm::Bucket.find_by(
          kind: b[:kind], target: b[:target],
          operation: b[:operation], bucket_start: b[:bucket_start]
        )
      end
      map
    end

    def maybe_cleanup
      return if Time.now - @last_cleanup_at < CLEANUP_INTERVAL

      @last_cleanup_at = Time.now
      cleanup_expired_data
    end

    def cleanup_expired_data
      cutoff = Catpm.config.retention_period.ago
      batch_size = 1_000

      [Catpm::Bucket, Catpm::Sample].each do |model|
        time_column = model == Catpm::Sample ? :recorded_at : :bucket_start
        loop do
          deleted = model.where(time_column => ...cutoff).limit(batch_size).delete_all
          break if deleted < batch_size
        end
      end

      Catpm::ErrorRecord.where(last_occurred_at: ...cutoff).limit(batch_size).delete_all
    end
  end
end
