# frozen_string_literal: true

require 'zlib'

module Catpm
  module Adapter
    module PostgreSQL
      extend Base

      class << self
        def persist_buckets(aggregated_buckets)
          return if aggregated_buckets.empty?

          ActiveRecord::Base.connection_pool.with_connection do |conn|
            aggregated_buckets.each_slice(Catpm.config.persistence_batch_size) do |batch|
              batch.each do |bucket_data|
                lock_id = advisory_lock_key(
                  "bucket:#{bucket_data[:kind]}:#{bucket_data[:target]}:" \
                  "#{bucket_data[:operation]}:#{bucket_data[:bucket_start]}"
                )

                ActiveRecord::Base.transaction do
                  conn.execute("SELECT pg_advisory_xact_lock(#{lock_id})")

                  existing = Catpm::Bucket.find_by(
                    kind: bucket_data[:kind],
                    target: bucket_data[:target],
                    operation: bucket_data[:operation],
                    bucket_start: bucket_data[:bucket_start]
                  )

                  if existing
                    merged_metadata = merge_metadata_sum(
                      existing.metadata_sum, bucket_data[:metadata_sum]
                    )
                    merged_digest = merge_digest(
                      existing.p95_digest, bucket_data[:p95_digest]
                    )

                    existing.update!(
                      count: existing.count + bucket_data[:count],
                      success_count: existing.success_count + bucket_data[:success_count],
                      failure_count: existing.failure_count + bucket_data[:failure_count],
                      duration_sum: existing.duration_sum + bucket_data[:duration_sum],
                      duration_max: [existing.duration_max, bucket_data[:duration_max]].max,
                      duration_min: [existing.duration_min, bucket_data[:duration_min]].min,
                      metadata_sum: merged_metadata,
                      p95_digest: merged_digest
                    )
                  else
                    Catpm::Bucket.create!(
                      kind: bucket_data[:kind],
                      target: bucket_data[:target],
                      operation: bucket_data[:operation],
                      bucket_start: bucket_data[:bucket_start],
                      count: bucket_data[:count],
                      success_count: bucket_data[:success_count],
                      failure_count: bucket_data[:failure_count],
                      duration_sum: bucket_data[:duration_sum],
                      duration_max: bucket_data[:duration_max],
                      duration_min: bucket_data[:duration_min],
                      metadata_sum: bucket_data[:metadata_sum],
                      p95_digest: bucket_data[:p95_digest]
                    )
                  end
                end
              end
            end
          end
        end

        def persist_event_buckets(event_buckets)
          return if event_buckets.empty?

          ActiveRecord::Base.connection_pool.with_connection do |conn|
            event_buckets.each_slice(Catpm.config.persistence_batch_size) do |batch|
              batch.each do |bucket_data|
                lock_id = advisory_lock_key("event_bucket:#{bucket_data[:name]}:#{bucket_data[:bucket_start]}")

                ActiveRecord::Base.transaction do
                  conn.execute("SELECT pg_advisory_xact_lock(#{lock_id})")

                  existing = Catpm::EventBucket.find_by(
                    name: bucket_data[:name],
                    bucket_start: bucket_data[:bucket_start]
                  )

                  if existing
                    existing.update!(count: existing.count + bucket_data[:count])
                  else
                    Catpm::EventBucket.create!(
                      name: bucket_data[:name],
                      bucket_start: bucket_data[:bucket_start],
                      count: bucket_data[:count]
                    )
                  end
                end
              end
            end
          end
        end

        def persist_event_samples(event_samples)
          return if event_samples.empty?

          ActiveRecord::Base.connection_pool.with_connection do
            max = Catpm.config.events_max_samples_per_name

            event_samples.each_slice(Catpm.config.persistence_batch_size) do |batch|
              records = batch.map do |sample_data|
                { name: sample_data[:name], payload: sample_data[:payload], recorded_at: sample_data[:recorded_at] }
              end
              Catpm::EventSample.insert_all(records) if records.any?
            end

            # Rotate: delete oldest samples beyond max per name
            event_samples.map { |s| s[:name] }.uniq.each do |name|
              count = Catpm::EventSample.where(name: name).count
              if count > max
                excess_ids = Catpm::EventSample.where(name: name)
                  .order(recorded_at: :asc)
                  .limit(count - max)
                  .pluck(:id)
                Catpm::EventSample.where(id: excess_ids).delete_all
              end
            end
          end
        end

        def persist_errors(error_records)
          return if error_records.empty?

          ActiveRecord::Base.connection_pool.with_connection do |conn|
            error_records.each_slice(Catpm.config.persistence_batch_size) do |batch|
              batch.each do |error_data|
                lock_id = advisory_lock_key("error:#{error_data[:fingerprint]}")

                ActiveRecord::Base.transaction do
                  conn.execute("SELECT pg_advisory_xact_lock(#{lock_id})")

                  existing = Catpm::ErrorRecord.find_by(fingerprint: error_data[:fingerprint])

                  if existing
                    merged_contexts = merge_contexts(
                      existing.parsed_contexts, error_data[:new_contexts]
                    )
                    merged_buckets = merge_occurrence_buckets(
                      existing.occurrence_buckets, error_data[:occurrence_times]
                    )

                    attrs = {
                      occurrences_count: existing.occurrences_count + error_data[:occurrences_count],
                      last_occurred_at: [existing.last_occurred_at, error_data[:last_occurred_at]].max,
                      contexts: merged_contexts,
                      occurrence_buckets: merged_buckets
                    }
                    attrs[:resolved_at] = nil if existing.resolved?

                    existing.update!(attrs)
                  else
                    initial_buckets = merge_occurrence_buckets(nil, error_data[:occurrence_times])

                    Catpm::ErrorRecord.create!(
                      fingerprint: error_data[:fingerprint],
                      kind: error_data[:kind],
                      error_class: error_data[:error_class],
                      message: error_data[:message],
                      occurrences_count: error_data[:occurrences_count],
                      first_occurred_at: error_data[:first_occurred_at],
                      last_occurred_at: error_data[:last_occurred_at],
                      contexts: error_data[:new_contexts],
                      occurrence_buckets: initial_buckets
                    )
                  end
                end
              end
            end
          end
        end

        def modulo_bucket_sql(interval)
          "EXTRACT(EPOCH FROM bucket_start)::integer % #{interval.to_i} = 0"
        end

        def table_sizes
          ActiveRecord::Base.connection_pool.with_connection do |conn|
            rows = conn.select_all(<<~SQL)
              SELECT c.relname AS name,
                     pg_total_relation_size(c.oid) AS total_bytes,
                     pg_table_size(c.oid) AS table_bytes,
                     pg_indexes_size(c.oid) AS index_bytes,
                     c.reltuples::bigint AS row_estimate
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relname LIKE 'catpm_%' AND c.relkind = 'r' AND n.nspname = 'public'
              ORDER BY pg_total_relation_size(c.oid) DESC
            SQL
            rows.map(&:symbolize_keys)
          end
        end

        private

        def advisory_lock_key(identifier)
          Zlib.crc32(identifier.to_s) & 0x7FFFFFFF
        end
      end
    end
  end
end
