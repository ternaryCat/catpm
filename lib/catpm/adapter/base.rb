# frozen_string_literal: true

module Catpm
  module Adapter
    module Base
      MINUTE_BUCKET_RETENTION = 48 * 3600
      HOUR_BUCKET_RETENTION = 90 * 86400
      DAY_BUCKET_RETENTION = 2 * 365 * 86400
      def persist_buckets(aggregated_buckets)
        raise NotImplementedError
      end

      def persist_errors(error_records)
        raise NotImplementedError
      end

      def persist_event_buckets(event_buckets)
        raise NotImplementedError
      end

      def persist_event_samples(event_samples)
        raise NotImplementedError
      end

      def persist_samples(samples, bucket_map)
        ActiveRecord::Base.connection_pool.with_connection do
          samples.each_slice(Catpm.config.persistence_batch_size) do |batch|
            records = batch.filter_map do |sample_data|
              bucket = bucket_map[sample_data[:bucket_key]]
              next unless bucket

              {
                bucket_id: bucket.id,
                kind: sample_data[:kind],
                sample_type: sample_data[:sample_type],
                recorded_at: sample_data[:recorded_at],
                duration: sample_data[:duration],
                context: sample_data[:context],
                error_fingerprint: sample_data[:error_fingerprint]
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

      def merge_digest(existing_blob, new_blob)
        existing = existing_blob ? TDigest.deserialize(existing_blob) : TDigest.new
        incoming = new_blob ? TDigest.deserialize(new_blob) : TDigest.new
        existing.merge(incoming)
        existing.empty? ? nil : existing.serialize
      end

      def merge_contexts(existing_contexts, new_contexts)
        combined = (existing_contexts + new_contexts)
        max = Catpm.config.max_error_contexts
        max ? combined.last(max) : combined
      end

      # Merge new occurrence timestamps into the multi-resolution bucket structure.
      # Structure: { "m" => {epoch => count}, "h" => {epoch => count}, "d" => {epoch => count} }
      # - "m" (minute): kept for 48 hours
      # - "h" (hour): kept for 90 days
      # - "d" (day): kept for 2 years
      def merge_occurrence_buckets(existing, new_times)
        buckets = parse_occurrence_buckets(existing)

        (new_times || []).each do |t|
          ts = t.to_i
          m_key = ((ts / 60) * 60).to_s
          h_key = ((ts / 3600) * 3600).to_s
          d_key = ((ts / 86400) * 86400).to_s

          buckets['m'][m_key] = (buckets['m'][m_key] || 0) + 1
          buckets['h'][h_key] = (buckets['h'][h_key] || 0) + 1
          buckets['d'][d_key] = (buckets['d'][d_key] || 0) + 1
        end

        # Compact old entries
        now = Time.current.to_i
        cutoff_m = now - MINUTE_BUCKET_RETENTION
        cutoff_h = now - HOUR_BUCKET_RETENTION
        cutoff_d = now - DAY_BUCKET_RETENTION

        buckets['m'].reject! { |k, _| k.to_i < cutoff_m }
        buckets['h'].reject! { |k, _| k.to_i < cutoff_h }
        buckets['d'].reject! { |k, _| k.to_i < cutoff_d }

        buckets
      end

      private

      def parse_occurrence_buckets(value)
        raw = parse_json(value)
        {
          'm' => (raw['m'].is_a?(Hash) ? raw['m'] : {}),
          'h' => (raw['h'].is_a?(Hash) ? raw['h'] : {}),
          'd' => (raw['d'].is_a?(Hash) ? raw['d'] : {})
        }
      end

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
