# frozen_string_literal: true

module Catpm
  class EventBucket < ApplicationRecord
    self.table_name = 'catpm_event_buckets'

    validates :name, :bucket_start, presence: true

    scope :by_name, ->(name) { where(name: name) }
    scope :recent, ->(period = 1.hour) { where(bucket_start: period.ago..) }
  end
end
