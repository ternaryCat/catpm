# frozen_string_literal: true

module Catpm
  class EventPref < ActiveRecord::Base
    self.table_name = 'catpm_event_prefs'

    scope :pinned, -> { where(pinned: true) }
    scope :ignored, -> { where(ignored: true) }

    def self.lookup(name)
      find_or_initialize_by(name: name)
    end
  end
end
