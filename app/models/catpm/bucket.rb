# frozen_string_literal: true

module Catpm
  class Bucket < ApplicationRecord
    self.table_name = 'catpm_buckets'

    has_many :samples, class_name: 'Catpm::Sample', foreign_key: :bucket_id, dependent: :delete_all

    validates :kind, :target, :bucket_start, presence: true

    scope :by_kind, ->(kind) { where(kind: kind) }
    scope :recent, ->(period = 1.hour) { where(bucket_start: period.ago..) }

    def average_duration
      return 0.0 if count.zero?
      duration_sum / count
    end

    def failure_rate
      return 0.0 if count.zero?
      failure_count.to_f / count
    end

    def percentile(p)
      digest = tdigest
      return nil if digest.nil? || digest.empty?
      digest.percentile(p)
    end

    def tdigest
      return nil if p95_digest.blank?
      TDigest.deserialize(p95_digest)
    end

    def parsed_metadata_sum
      case metadata_sum
      when Hash then metadata_sum
      when String then JSON.parse(metadata_sum)
      else {}
      end
    rescue JSON::ParserError
      {}
    end
  end
end
