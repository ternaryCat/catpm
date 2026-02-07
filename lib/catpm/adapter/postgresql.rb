# frozen_string_literal: true

module Catpm
  module Adapter
    module PostgreSQL
      extend Base

      class << self
        def persist_buckets(aggregated_buckets)
          return if aggregated_buckets.empty?

          ActiveRecord::Base.connection_pool.with_connection do
            # For p95_digest and metadata_sum, we need read-modify-write with advisory lock
            # because these fields require non-trivial merge logic
            aggregated_buckets.each_slice(100) do |batch|
              bucket_records = batch.map do |b|
                {
                  kind: b[:kind],
                  target: b[:target],
                  operation: b[:operation],
                  bucket_start: b[:bucket_start],
                  count: b[:count],
                  success_count: b[:success_count],
                  failure_count: b[:failure_count],
                  duration_sum: b[:duration_sum],
                  duration_max: b[:duration_max],
                  duration_min: b[:duration_min],
                  metadata_sum: b[:metadata_sum]&.to_json,
                  p95_digest: b[:p95_digest]
                }
              end

              Catpm::Bucket.upsert_all(
                bucket_records,
                unique_by: %i[kind target operation bucket_start],
                on_duplicate: Arel.sql(<<~SQL)
                  count = catpm_buckets.count + excluded.count,
                  success_count = catpm_buckets.success_count + excluded.success_count,
                  failure_count = catpm_buckets.failure_count + excluded.failure_count,
                  duration_sum = catpm_buckets.duration_sum + excluded.duration_sum,
                  duration_max = GREATEST(catpm_buckets.duration_max, excluded.duration_max),
                  duration_min = LEAST(catpm_buckets.duration_min, excluded.duration_min),
                  metadata_sum = excluded.metadata_sum,
                  p95_digest = excluded.p95_digest
                SQL
              )
            end
          end
        end

        def persist_errors(error_records)
          return if error_records.empty?

          ActiveRecord::Base.connection_pool.with_connection do
            error_records.each_slice(100) do |batch|
              records = batch.map do |e|
                {
                  fingerprint: e[:fingerprint],
                  kind: e[:kind],
                  error_class: e[:error_class],
                  message: e[:message],
                  occurrences_count: e[:occurrences_count],
                  first_occurred_at: e[:first_occurred_at],
                  last_occurred_at: e[:last_occurred_at],
                  contexts: e[:new_contexts].to_json
                }
              end

              Catpm::ErrorRecord.upsert_all(
                records,
                unique_by: :fingerprint,
                on_duplicate: Arel.sql(<<~SQL)
                  occurrences_count = catpm_errors.occurrences_count + excluded.occurrences_count,
                  last_occurred_at = GREATEST(catpm_errors.last_occurred_at, excluded.last_occurred_at),
                  contexts = excluded.contexts
                SQL
              )
            end
          end
        end

        def modulo_bucket_sql(interval)
          "EXTRACT(EPOCH FROM bucket_start)::integer % #{interval.to_i} = 0"
        end
      end
    end
  end
end
