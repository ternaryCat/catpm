# frozen_string_literal: true

module Catpm
  module Adapter
    module Base
      def persist_buckets(aggregated_buckets)
        raise NotImplementedError
      end

      def persist_errors(error_records)
        raise NotImplementedError
      end

      def persist_samples(samples, bucket_map)
        ActiveRecord::Base.connection_pool.with_connection do
          samples.each_slice(100) do |batch|
            records = batch.filter_map do |sample_data|
              bucket = bucket_map[sample_data[:bucket_key]]
              next unless bucket

              {
                bucket_id: bucket.id,
                kind: sample_data[:kind],
                sample_type: sample_data[:sample_type],
                recorded_at: sample_data[:recorded_at],
                duration: sample_data[:duration],
                context: sample_data[:context]&.to_json
              }
            end

            Catpm::Sample.insert_all(records) if records.any?
          end
        end
      end

      def modulo_bucket_sql(interval)
        raise NotImplementedError
      end

      def merge_metadata_sum(existing, incoming)
        existing = parse_json(existing)
        incoming = parse_json(incoming)

        incoming.each do |key, value|
          existing[key] = (existing[key] || 0).to_f + value.to_f
        end

        existing
      end

      private

      def parse_json(value)
        case value
        when Hash then value.transform_keys(&:to_s)
        when String then JSON.parse(value)
        when NilClass then {}
        else {}
        end
      rescue JSON::ParserError
        {}
      end
    end
  end
end
