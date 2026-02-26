# frozen_string_literal: true

module Catpm
  class SystemController < ApplicationController
    def index
      @stats = Catpm.stats
      @buffer_size = Catpm.buffer&.size || 0
      @buffer_bytes = Catpm.buffer&.current_bytes || 0
      @config = Catpm.config
      @oldest_bucket = Catpm::Bucket.minimum(:bucket_start)
      @active_error_count = Catpm::ErrorRecord.unresolved.count
      @table_sizes = Catpm::Adapter.current.table_sizes
    end

    def pipeline
      render layout: "catpm/pipeline"
    end
  end
end
