# frozen_string_literal: true

module Catpm
  class EventSample < ApplicationRecord
    self.table_name = 'catpm_event_samples'

    validates :name, :recorded_at, presence: true

    scope :by_name, ->(name) { where(name: name) }
    scope :recent, ->(period = 1.hour) { where(recorded_at: period.ago..) }

    def parsed_payload
      case payload
      when Hash then payload
      when String then JSON.parse(payload)
      else {}
      end
    rescue JSON::ParserError
      {}
    end
  end
end
