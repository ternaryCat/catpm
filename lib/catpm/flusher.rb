# frozen_string_literal: true

module Catpm
  class Flusher
    ERROR_LOG_BACKTRACE_LINES = 5

    attr_reader :running

    def initialize(buffer:, interval: nil, jitter: nil)
      @buffer = buffer
      @interval = interval || Catpm.config.flush_interval
      @jitter = jitter || Catpm.config.flush_jitter
      @circuit = CircuitBreaker.new
      @last_cleanup_at = Time.now
      @running = false
      @thread = nil
      @pid = nil
      @mutex = Mutex.new
    end

    def start
      @mutex.synchronize do
        # After fork(), threads are dead but @running may still be true
        if @pid && @pid != Process.pid
          @running = false
          @thread = nil
        end

        return if @running

        @running = true
        @pid = Process.pid
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
    end

    # Cheap check called from middleware on every request.
    # Detects fork (Puma, Unicorn, etc.) and restarts the thread.
    def ensure_running!
      return if @running && @thread&.alive? && @pid == Process.pid

      start
    end

    def stop(timeout: Catpm.config.shutdown_timeout)
      thread = nil

      @mutex.synchronize do
        return unless @running

        @running = false
        thread = @thread
        @thread = nil
      end

      thread&.join(timeout)
      flush_cycle # Final flush
    end

    # Public for testing and emergency flush
    def flush_cycle
      return if @circuit.open?

      events = @buffer.drain
      return if events.empty?

      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          perf_events, custom_events = events.partition { |e| e.is_a?(Catpm::Event) }

          if perf_events.any?
            buckets, samples, errors = aggregate(perf_events)

            adapter = Catpm::Adapter.current
            adapter.persist_buckets(buckets)

            bucket_map = build_bucket_map(buckets)
            adapter.persist_samples(samples, bucket_map)
            trim_samples(samples)
            adapter.persist_errors(errors)
          end

          if custom_events.any?
            event_buckets, event_samples = aggregate_custom_events(custom_events)

            adapter = Catpm::Adapter.current
            adapter.persist_event_buckets(event_buckets)
            adapter.persist_event_samples(event_samples)
          end
        end
      end

      @circuit.record_success
      Catpm.stats[:flushes] += 1

      maybe_cleanup
    rescue => e
      events&.each { |ev| @buffer.push(ev) }
      @circuit.record_failure
      Catpm.config.error_handler.call(e)
      Rails.logger.error("[catpm] flush error: #{e.class}: #{e.message}\n#{e.backtrace&.first(ERROR_LOG_BACKTRACE_LINES)&.join("\n")}")
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

        # Compute error fingerprint (used for both samples and error grouping)
        error_fp = nil
        if event.error?
          error_fp = Catpm::Fingerprint.generate(
            kind: event.kind,
            error_class: event.error_class,
            backtrace: event.backtrace
          )
        end

        # Collect samples (pre-determined by collector — only these events carry full context)
        sample_type = event.sample_type
        if sample_type
          sample_hash = {
            bucket_key: key,
            kind: event.kind,
            sample_type: sample_type,
            recorded_at: event.started_at,
            duration: event.duration,
            context: event.context || {}
          }
          sample_hash[:error_fingerprint] = error_fp if error_fp
          samples << sample_hash
        end

        # Error grouping
        if error_fp
          error = error_groups[error_fp] ||= {
            fingerprint: error_fp,
            kind: event.kind,
            error_class: event.error_class,
            message: event.error_message,
            occurrences_count: 0,
            first_occurred_at: event.started_at,
            last_occurred_at: event.started_at,
            new_contexts: [],
            occurrence_times: []
          }

          error[:occurrences_count] += 1
          error[:last_occurred_at] = [ error[:last_occurred_at], event.started_at ].max
          error[:occurrence_times] << event.started_at

          max_ctx = Catpm.config.max_error_contexts
          if max_ctx.nil? || error[:new_contexts].size < max_ctx
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


    # Trim excess samples AFTER insert. Simpler and guaranteed correct —
    # no stale-cache issues when a single flush batch crosses the limit.
    def trim_samples(samples)
      return if samples.empty?

      endpoint_keys = samples.map { |s| s[:bucket_key][0..2] }.uniq

      endpoint_keys.each do |kind, target, operation|
        endpoint_scope = Catpm::Sample.joins(:bucket)
          .where(catpm_buckets: { kind: kind, target: target, operation: operation })

        # Random: keep newest N
        max_random = Catpm.config.max_random_samples_per_endpoint
        trim_by_column(endpoint_scope.where(sample_type: 'random'), max_random, :recorded_at) if max_random

        # Slow: keep highest-duration N
        max_slow = Catpm.config.max_slow_samples_per_endpoint
        trim_by_column(endpoint_scope.where(sample_type: 'slow'), max_slow, :duration) if max_slow

      end

      # Errors: per-fingerprint cap (keep newest within each fingerprint)
      max_err_fp = Catpm.config.max_error_samples_per_fingerprint
      if max_err_fp
        fps = samples.filter_map { |s| s[:error_fingerprint] }.uniq
        fps.each do |fp|
          trim_by_column(Catpm::Sample.where(sample_type: 'error', error_fingerprint: fp), max_err_fp, :recorded_at)
        end
      end
    end

    def trim_by_column(scope, max, keep_column)
      count = scope.count
      return if count <= max

      excess_ids = scope.order(keep_column => :asc).limit(count - max).pluck(:id)
      Catpm::Sample.where(id: excess_ids).delete_all if excess_ids.any?
    end

    def build_error_context(event)
      event_context = event.context || {}
      ctx = {
        occurred_at: event.started_at.iso8601,
        kind: event.kind,
        operation: event_context.slice(:method, :path, :params, :job_class, :job_id, :queue, :target, :metadata),
        backtrace: event.backtrace || [],
        duration: event.duration,
        status: event.status
      }

      ctx[:target] = event.target if event.target.present?

      if event_context[:segments]
        ctx[:segments] = event_context[:segments]
        ctx[:segments_capped] = event_context[:segments_capped]
      end

      if event_context[:segment_summary]
        ctx[:segment_summary] = event_context[:segment_summary]
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
          if max.nil? || sample_counts[event.name] < max
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
      Collector.reset_sample_counts!
    end

    def downsample_buckets
      bucket_sizes = Catpm.config.bucket_sizes
      thresholds = Catpm.config.downsampling_thresholds
      adapter = Catpm::Adapter.current

      # Phase 1: Merge 1-minute buckets older than 1 hour into 5-minute buckets
      downsample_tier(
        target_interval: bucket_sizes[:medium],
        age_threshold: thresholds[:medium],
        adapter: adapter
      )

      # Phase 2: Merge 5-minute buckets older than 24 hours into 1-hour buckets
      downsample_tier(
        target_interval: bucket_sizes[:hourly],
        age_threshold: thresholds[:hourly],
        adapter: adapter
      )

      # Phase 3: Merge 1-hour buckets older than 1 week into 1-day buckets
      downsample_tier(
        target_interval: bucket_sizes[:daily],
        age_threshold: thresholds[:daily],
        adapter: adapter
      )

      # Phase 4: Merge 1-day buckets older than 3 months into 1-week buckets
      downsample_tier(
        target_interval: bucket_sizes[:weekly],
        age_threshold: thresholds[:weekly],
        adapter: adapter
      )

      # Event buckets: same downsampling tiers
      downsample_event_tier(target_interval: bucket_sizes[:medium], age_threshold: thresholds[:medium], adapter: adapter)
      downsample_event_tier(target_interval: bucket_sizes[:hourly], age_threshold: thresholds[:hourly], adapter: adapter)
      downsample_event_tier(target_interval: bucket_sizes[:daily], age_threshold: thresholds[:daily], adapter: adapter)
      downsample_event_tier(target_interval: bucket_sizes[:weekly], age_threshold: thresholds[:weekly], adapter: adapter)
    end

    def downsample_tier(target_interval:, age_threshold:, adapter:)
      cutoff = age_threshold.ago
      target_seconds = target_interval.to_i

      # Process in batches to avoid loading all old buckets into memory
      Catpm::Bucket.where(bucket_start: ...cutoff)
        .select(:id, :kind, :target, :operation, :bucket_start)
        .group_by { |b| [b.kind, b.target, b.operation] }
        .each do |(_kind, _target, _operation), endpoint_buckets|
          groups = endpoint_buckets.group_by do |bucket|
            epoch = bucket.bucket_start.to_i
            aligned_epoch = epoch - (epoch % target_seconds)
            Time.at(aligned_epoch).utc
          end

          groups.each do |aligned_start, stub_buckets|
            next if stub_buckets.size == 1 && stub_buckets.first.bucket_start.to_i % target_seconds == 0

            # Load full records only for groups that need merging
            bucket_ids = stub_buckets.map(&:id)
            buckets = Catpm::Bucket.where(id: bucket_ids).to_a

            merged = {
              kind: buckets.first.kind,
              target: buckets.first.target,
              operation: buckets.first.operation,
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

            survivor = buckets.first

            # Reassign all samples to the survivor bucket
            Catpm::Sample.where(bucket_id: bucket_ids).update_all(bucket_id: survivor.id)

            # Delete non-survivor source buckets (now sample-free)
            Catpm::Bucket.where(id: bucket_ids - [survivor.id]).delete_all

            # Overwrite survivor with merged data
            survivor.update!(
              bucket_start: aligned_start,
              count: merged[:count],
              success_count: merged[:success_count],
              failure_count: merged[:failure_count],
              duration_sum: merged[:duration_sum],
              duration_max: merged[:duration_max],
              duration_min: merged[:duration_min],
              metadata_sum: merged[:metadata_sum],
              p95_digest: merged[:p95_digest]
            )
          end
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
      batch_size = Catpm.config.cleanup_batch_size

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
