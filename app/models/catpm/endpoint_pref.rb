# frozen_string_literal: true

module Catpm
  class EndpointPref < ActiveRecord::Base
    self.table_name = 'catpm_endpoint_prefs'

    scope :pinned, -> { where(pinned: true) }
    scope :ignored, -> { where(ignored: true) }

    def self.lookup(kind, target, operation)
      find_or_initialize_by(kind: kind, target: target, operation: operation.presence || '')
    end
  end
end
