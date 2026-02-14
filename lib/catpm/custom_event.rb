# frozen_string_literal: true

module Catpm
  class CustomEvent
    OBJECT_OVERHEAD = 40
    REF_SIZE = 8

    attr_accessor :name, :payload, :recorded_at

    def initialize(name:, payload: {}, recorded_at: nil)
      @name = name.to_s
      @payload = payload || {}
      @recorded_at = recorded_at || Time.current
    end

    def bucket_start
      recorded_at.change(sec: 0)
    end

    def estimated_byte_size
      OBJECT_OVERHEAD +
        name.bytesize + REF_SIZE +
        payload_bytes
    end

    # Alias to match Event interface used by Buffer
    alias_method :estimated_bytes, :estimated_byte_size

    private

    def payload_bytes
      payload.sum { |k, v| k.to_s.bytesize + v.to_s.bytesize + REF_SIZE }
    rescue
      0
    end
  end
end
