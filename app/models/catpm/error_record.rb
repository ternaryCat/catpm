# frozen_string_literal: true

module Catpm
  class ErrorRecord < ApplicationRecord
    self.table_name = "catpm_errors"

    validates :fingerprint, :kind, :error_class, :first_occurred_at, :last_occurred_at, presence: true
    validates :fingerprint, uniqueness: true

    scope :by_kind, ->(kind) { where(kind: kind) }
    scope :unresolved, -> { where(resolved_at: nil) }
    scope :resolved, -> { where.not(resolved_at: nil) }
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
  end
end
