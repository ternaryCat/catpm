# frozen_string_literal: true

module Catpm
  class Flusher
    attr_reader :running

    def initialize(buffer:, interval: nil, jitter: nil)
      @buffer = buffer
      @interval = interval || Catpm.config.flush_interval
      @jitter = jitter || Catpm.config.flush_jitter
      @circuit = CircuitBreaker.new
      @last_cleanup_at = Time.now
      @running = false
      @thread = nil
    end

    def start
      return if @running

      @running = true
      @thread = Thread.new do
        while @running
          sleep(effective_interval)
          flush_cycle if @running
        end
      rescue => e
        Catpm.config.error_handler.call(e)
        retry if @running
      end
    end

    def stop(timeout: Catpm.config.shutdown_timeout)
      return unless @running

      @running = false
      @thread&.join(timeout)
      flush_cycle # Final flush
    end

    # Public for testing and emergency flush
    def flush_cycle
      return if @circuit.open?

      events = @buffer.drain
      return if events.empty?

      ActiveRecord::Base.connection_pool.with_connection do
        perf_events, custom_events = events.partition { |e| e.is_a?(Catpm::Event) }

        if perf_events.any?
          buckets, samples, errors = aggregate(perf_events)

          adapter = Catpm::Adapter.current
          adapter.persist_buckets(buckets)

          bucket_map = build_bucket_map(buckets)
          samples = rotate_samples(samples)
          adapter.persist_samples(samples, bucket_map)
          adapter.persist_errors(errors)
        end

        if custom_events.any?
          event_buckets, event_samples = aggregate_custom_events(custom_events)

          adapter = Catpm::Adapter.current
          adapter.persist_event_buckets(event_buckets)
          adapter.persist_event_samples(event_samples)
        end
      end

      @circuit.record_success
      Catpm.stats[:flushes] += 1

      maybe_cleanup
    rescue => e
      events&.each { |ev| @buffer.push(ev) }
      @circuit.record_failure
      Catpm.config.error_handler.call(e)
      Rails.logger.error("[catpm] flush error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
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
      Catpm::Sample.where(sample_type: 'random')
        .joins(:bucket)
        .group('catpm_buckets.kind', 'catpm_buckets.target', 'catpm_buckets.operation')
        .count
        .each { |(kind, target, op), cnt| @random_sample_counts[[ kind, target, op ]] = cnt }

      events.each do |event|
        # Bucket aggregation
        key = [ event.kind, event.target, event.operation, event.bucket_start ]
        bucket = bucket_groups[key] ||= new_bucket_hash(event)

        bucket[:count] += 1
        if event.success?
          bucket[:success_count] += 1
        else
          bucket[:failure_count] += 1
        end
        bucket[:duration_sum] += event.duration
        bucket[:duration_max] = [ bucket[:duration_max], event.duration ].max
        bucket[:duration_min] = [ bucket[:duration_min], event.duration ].min

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
          error[:last_occurred_at] = [ error[:last_occurred_at], event.started_at ].max

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

      [ buckets, samples, error_groups.values ]
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
      return 'error' if event.error?

      threshold = Catpm.config.slow_threshold_for(event.kind.to_sym)
      return 'slow' if event.duration >= threshold

      # Always sample if endpoint has few random samples (filling phase)
      endpoint_key = [ event.kind, event.target, event.operation ]
      existing_random = @random_sample_counts[endpoint_key] || 0
      if existing_random < Catpm.config.max_random_samples_per_endpoint
        @random_sample_counts[endpoint_key] = existing_random + 1
        return 'random'
      end

      return 'random' if rand(Catpm.config.random_sample_rate) == 0

      nil
    end

    def rotate_samples(samples)
      samples.each do |sample|
        kind, target, operation = sample[:bucket_key][0], sample[:bucket_key][1], sample[:bucket_key][2]
        endpoint_samples = Catpm::Sample
          .joins(:bucket)
          .where(catpm_buckets: { kind: kind, target: target, operation: operation })

        case sample[:sample_type]
        when 'random'
          existing = endpoint_samples.where(sample_type: 'random')
          if existing.count >= Catpm.config.max_random_samples_per_endpoint
            existing.order(recorded_at: :asc).first.destroy
          end
        when 'slow'
          existing = endpoint_samples.where(sample_type: 'slow')
          if existing.count >= Catpm.config.max_slow_samples_per_endpoint
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
        backtrace: (event.backtrace || []).first(Catpm.config.backtrace_lines),
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
        key = [ b[:kind], b[:target], b[:operation], b[:bucket_start] ]
        map[key] = Catpm::Bucket.find_by(
          kind: b[:kind], target: b[:target],
          operation: b[:operation], bucket_start: b[:bucket_start]
        )
      end
      map
    end

    def aggregate_custom_events(events)
      bucket_groups = {}
      samples = []
      sample_counts = Hash.new(0)

      events.each do |event|
        key = [event.name, event.bucket_start]
        bucket_groups[key] ||= { name: event.name, bucket_start: event.bucket_start, count: 0 }
        bucket_groups[key][:count] += 1

        max = Catpm.config.events_max_samples_per_name
        if event.payload.any?
          if sample_counts[event.name] < max
            samples << { name: event.name, payload: event.payload, recorded_at: event.recorded_at }
            sample_counts[event.name] += 1
          elsif rand(Catpm.config.random_sample_rate) == 0
            samples << { name: event.name, payload: event.payload, recorded_at: event.recorded_at }
          end
        end
      end

      [bucket_groups.values, samples]
    end

    def maybe_cleanup
      return if Time.now - @last_cleanup_at < Catpm.config.cleanup_interval

      @last_cleanup_at = Time.now
      downsample_buckets
      cleanup_expired_data if Catpm.config.retention_period
    end

    def downsample_buckets
      bucket_sizes = Catpm.config.bucket_sizes
      adapter = Catpm::Adapter.current

      # Phase 1: Merge 1-minute buckets older than 1 hour into 5-minute buckets
      downsample_tier(
        target_interval: bucket_sizes[:medium],
        age_threshold: 1.hour,
        adapter: adapter
      )

      # Phase 2: Merge 5-minute buckets older than 24 hours into 1-hour buckets
      downsample_tier(
        target_interval: bucket_sizes[:hourly],
        age_threshold: 24.hours,
        adapter: adapter
      )

      # Phase 3: Merge 1-hour buckets older than 1 week into 1-day buckets
      downsample_tier(
        target_interval: bucket_sizes[:daily],
        age_threshold: 1.week,
        adapter: adapter
      )

      # Phase 4: Merge 1-day buckets older than 3 months into 1-week buckets
      downsample_tier(
        target_interval: bucket_sizes[:weekly],
        age_threshold: 90.days,
        adapter: adapter
      )

      # Event buckets: same downsampling tiers
      downsample_event_tier(target_interval: bucket_sizes[:medium], age_threshold: 1.hour, adapter: adapter)
      downsample_event_tier(target_interval: bucket_sizes[:hourly], age_threshold: 24.hours, adapter: adapter)
      downsample_event_tier(target_interval: bucket_sizes[:daily], age_threshold: 1.week, adapter: adapter)
      downsample_event_tier(target_interval: bucket_sizes[:weekly], age_threshold: 90.days, adapter: adapter)
    end

    def downsample_tier(target_interval:, age_threshold:, adapter:)
      cutoff = age_threshold.ago
      target_seconds = target_interval.to_i

      # Find all buckets older than cutoff
      source_buckets = Catpm::Bucket.where(bucket_start: ...cutoff).to_a
      return if source_buckets.empty?

      # Group by (kind, target, operation) + target-aligned bucket_start
      groups = source_buckets.group_by do |bucket|
        epoch = bucket.bucket_start.to_i
        aligned_epoch = epoch - (epoch % target_seconds)
        aligned_start = Time.at(aligned_epoch).utc

        [bucket.kind, bucket.target, bucket.operation, aligned_start]
      end

      groups.each do |(kind, target, operation, aligned_start), buckets|
        # Skip if only one bucket already at the target alignment
        next if buckets.size == 1 && buckets.first.bucket_start.to_i % target_seconds == 0

        merged = {
          kind: kind,
          target: target,
          operation: operation,
          bucket_start: aligned_start,
          count: buckets.sum(&:count),
          success_count: buckets.sum(&:success_count),
          failure_count: buckets.sum(&:failure_count),
          duration_sum: buckets.sum(&:duration_sum),
          duration_max: buckets.map(&:duration_max).max,
          duration_min: buckets.map(&:duration_min).min,
          metadata_sum: merge_bucket_metadata(buckets, adapter),
          p95_digest: merge_bucket_digests(buckets)
        }

        source_ids = buckets.map(&:id)

        # Delete source buckets first (to avoid unique constraint conflict
        # if one source bucket has the same bucket_start as the target)
        Catpm::Sample.where(bucket_id: source_ids).delete_all
        Catpm::Bucket.where(id: source_ids).delete_all

        # Create the merged bucket
        adapter.persist_buckets([merged])
      end
    end

    def downsample_event_tier(target_interval:, age_threshold:, adapter:)
      cutoff = age_threshold.ago
      target_seconds = target_interval.to_i

      source_buckets = Catpm::EventBucket.where(bucket_start: ...cutoff).to_a
      return if source_buckets.empty?

      groups = source_buckets.group_by do |bucket|
        epoch = bucket.bucket_start.to_i
        aligned_epoch = epoch - (epoch % target_seconds)
        aligned_start = Time.at(aligned_epoch).utc
        [bucket.name, aligned_start]
      end

      groups.each do |(name, aligned_start), buckets|
        next if buckets.size == 1 && buckets.first.bucket_start.to_i % target_seconds == 0

        merged = { name: name, bucket_start: aligned_start, count: buckets.sum(&:count) }
        Catpm::EventBucket.where(id: buckets.map(&:id)).delete_all
        adapter.persist_event_buckets([merged])
      end
    end

    def merge_bucket_metadata(buckets, adapter)
      buckets.reduce({}) do |acc, b|
        adapter.merge_metadata_sum(acc, b.metadata_sum)
      end
    end

    def merge_bucket_digests(buckets)
      combined = TDigest.new
      buckets.each do |b|
        next unless b.p95_digest
        digest = TDigest.deserialize(b.p95_digest)
        combined.merge(digest)
      end
      combined.empty? ? nil : combined.serialize
    end

    def cleanup_expired_data
      cutoff = Catpm.config.retention_period.ago
      batch_size = 1_000

      [ Catpm::Bucket, Catpm::Sample ].each do |model|
        time_column = model == Catpm::Sample ? :recorded_at : :bucket_start
        loop do
          deleted = model.where(time_column => ...cutoff).limit(batch_size).delete_all
          break if deleted < batch_size
        end
      end

      Catpm::ErrorRecord.where(last_occurred_at: ...cutoff).limit(batch_size).delete_all

      [Catpm::EventBucket, Catpm::EventSample].each do |model|
        time_column = model == Catpm::EventSample ? :recorded_at : :bucket_start
        loop do
          deleted = model.where(time_column => ...cutoff).limit(batch_size).delete_all
          break if deleted < batch_size
        end
      end
    end
  end
end
