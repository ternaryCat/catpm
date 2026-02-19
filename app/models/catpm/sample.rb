# frozen_string_literal: true

module Catpm
  class Sample < ApplicationRecord
    self.table_name = 'catpm_samples'

    belongs_to :bucket, class_name: 'Catpm::Bucket'

    validates :kind, :sample_type, :recorded_at, :duration, presence: true

    scope :by_kind, ->(kind) { where(kind: kind) }
    scope :slow, -> { where(sample_type: 'slow') }
    scope :errors, -> { where(sample_type: 'error') }
    scope :recent, ->(period = 1.hour) { where(recorded_at: period.ago..) }
    scope :for_error, ->(fingerprint) { where(error_fingerprint: fingerprint) }

    def parsed_context
      case context
      when Hash then context
      when String then JSON.parse(context)
      else {}
      end
    rescue JSON::ParserError
      {}
    end
  end
end
