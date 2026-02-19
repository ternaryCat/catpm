# frozen_string_literal: true

module Catpm
  class Event
    OBJECT_OVERHEAD = 40 # bytes, Ruby object header
    REF_SIZE = 8         # bytes, pointer on 64-bit
    NUMERIC_FIELDS_SIZE = 64 # fixed numeric fields (duration, timestamps, etc.)

    attr_accessor :kind, :target, :operation, :duration, :started_at,
                  :metadata, :error_class, :error_message, :backtrace,
                  :sample_type, :context, :status

    def initialize(kind:, target:, operation: '', duration: 0.0, started_at: nil,
                   metadata: {}, error_class: nil, error_message: nil, backtrace: nil,
                   sample_type: nil, context: {}, status: nil)
      @kind = kind.to_s
      @target = target.to_s
      @operation = (operation || '').to_s
      @duration = duration.to_f
      @started_at = started_at || Time.current
      @metadata = metadata || {}
      @error_class = error_class
      @error_message = error_message
      @backtrace = backtrace
      @sample_type = sample_type
      @context = context || {}
      @status = status
    end

    def estimated_bytes
      OBJECT_OVERHEAD +
        target.bytesize + REF_SIZE +
        operation.bytesize +
        kind.bytesize +
        (error_class&.bytesize || 0) +
        (error_message&.bytesize || 0) +
        backtrace_bytes +
        context_bytes +
        metadata_bytes +
        NUMERIC_FIELDS_SIZE
    end

    def error?
      !error_class.nil?
    end

    def success?
      !error?
    end

    def bucket_start
      started_at.change(sec: 0) # Round to minute
    end

    private

    def backtrace_bytes
      return 0 unless backtrace

      backtrace.sum { |line| line.bytesize + REF_SIZE } + REF_SIZE
    end

    def context_bytes
      return 0 if context.empty?

      context.to_json.bytesize + REF_SIZE
    end

    def metadata_bytes
      return 0 if metadata.empty?

      metadata.to_json.bytesize + REF_SIZE
    end
  end
end
