# frozen_string_literal: true

module Catpm
  class ErrorRecord < ApplicationRecord
    self.table_name = 'catpm_errors'

    validates :fingerprint, :kind, :error_class, :first_occurred_at, :last_occurred_at, presence: true
    validates :fingerprint, uniqueness: true

    scope :by_kind, ->(kind) { where(kind: kind) }
    scope :unresolved, -> { where(resolved_at: nil) }
    scope :resolved, -> { where.not(resolved_at: nil) }
    scope :pinned, -> { where(pinned: true) }
    scope :recent, ->(period = 24.hours) { where(last_occurred_at: period.ago..) }

    def resolved?
      resolved_at.present?
    end

    def resolve!
      update!(resolved_at: Time.current)
    end

    def unresolve!
      update!(resolved_at: nil)
    end

    def parsed_contexts
      case contexts
      when Array then contexts
      when String then JSON.parse(contexts)
      else []
      end
    rescue JSON::ParserError
      []
    end

    def parsed_occurrence_buckets
      raw = case occurrence_buckets
            when Hash then occurrence_buckets
            when String then JSON.parse(occurrence_buckets)
            else {}
      end
      {
        'm' => (raw['m'].is_a?(Hash) ? raw['m'] : {}),
        'h' => (raw['h'].is_a?(Hash) ? raw['h'] : {}),
        'd' => (raw['d'].is_a?(Hash) ? raw['d'] : {})
      }
    rescue JSON::ParserError
      { 'm' => {}, 'h' => {}, 'd' => {} }
    end
  end
end
