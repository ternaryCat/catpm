# frozen_string_literal: true

module Catpm
  class SystemController < ApplicationController
    def index
      @stats = Catpm.stats
      @buffer_size = Catpm.buffer&.size || 0
      @buffer_bytes = Catpm.buffer&.current_bytes || 0
      @config = Catpm.config
      @bucket_count = Catpm::Bucket.count
      @sample_count = Catpm::Sample.count
      @error_count = Catpm::ErrorRecord.count
      @oldest_bucket = Catpm::Bucket.minimum(:bucket_start)
      @active_error_count = Catpm::ErrorRecord.unresolved.count
    end
  end
end
