# frozen_string_literal: true

module Catpm
  module Adapter
    module SQLite
      extend Base

      class << self
        def persist_buckets(aggregated_buckets)
          return if aggregated_buckets.empty?

          with_write_lock do
            aggregated_buckets.each do |bucket_data|
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
                  metadata_sum: merged_metadata.to_json,
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
                  metadata_sum: bucket_data[:metadata_sum]&.to_json,
                  p95_digest: bucket_data[:p95_digest]
                )
              end
            end
          end
        end

        def persist_event_buckets(event_buckets)
          return if event_buckets.empty?

          with_write_lock do
            event_buckets.each do |bucket_data|
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

        def persist_event_samples(event_samples)
          return if event_samples.empty?

          max = Catpm.config.events_max_samples_per_name

          with_write_lock do
            event_samples.each_slice(Catpm.config.persistence_batch_size) do |batch|
              records = batch.map do |sample_data|
                { name: sample_data[:name], payload: sample_data[:payload]&.to_json, recorded_at: sample_data[:recorded_at] }
              end
              Catpm::EventSample.insert_all(records) if records.any?
            end

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

          with_write_lock do
            error_records.each do |error_data|
              existing = Catpm::ErrorRecord.find_by(fingerprint: error_data[:fingerprint])

              if existing
                merged_contexts = merge_contexts(
                  existing.parsed_contexts, error_data[:new_contexts]
                )

                attrs = {
                  occurrences_count: existing.occurrences_count + error_data[:occurrences_count],
                  last_occurred_at: [existing.last_occurred_at, error_data[:last_occurred_at]].max,
                  contexts: merged_contexts.to_json
                }
                attrs[:resolved_at] = nil if existing.resolved?

                existing.update!(attrs)
              else
                Catpm::ErrorRecord.create!(
                  fingerprint: error_data[:fingerprint],
                  kind: error_data[:kind],
                  error_class: error_data[:error_class],
                  message: error_data[:message],
                  occurrences_count: error_data[:occurrences_count],
                  first_occurred_at: error_data[:first_occurred_at],
                  last_occurred_at: error_data[:last_occurred_at],
                  contexts: error_data[:new_contexts].to_json
                )
              end
            end
          end
        end

        def modulo_bucket_sql(interval)
          "CAST(strftime('%s', bucket_start) AS INTEGER) % #{interval.to_i} = 0"
        end

        private

        def with_write_lock(&block)
          ActiveRecord::Base.connection_pool.with_connection do |conn|
            conn.raw_connection.busy_timeout = Catpm.config.sqlite_busy_timeout
            ActiveRecord::Base.transaction(&block)
          end
        end
      end
    end
  end
end
