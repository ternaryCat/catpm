# frozen_string_literal: true

module Catpm
  class StatusController < ApplicationController
    def index
      @buckets = Catpm::Bucket.order(bucket_start: :desc).limit(50)
      @samples = Catpm::Sample.order(recorded_at: :desc).limit(20)
      @errors = Catpm::ErrorRecord.order(last_occurred_at: :desc).limit(20)
      @stats = Catpm.stats
      @buffer_size = Catpm.buffer&.size || 0
      @buffer_bytes = Catpm.buffer&.current_bytes || 0
    end
  end
end
