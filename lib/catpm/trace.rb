# frozen_string_literal: true

module Catpm
  def self.trace(name, metadata: {}, context: {}, &block)
    unless enabled? && buffer
      return block.call if block
      return nil
    end

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = nil

    begin
      result = block.call
    rescue => e
      error = e
      raise
    ensure
      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0
      Collector.process_custom(
        name: name,
        duration: duration_ms,
        metadata: metadata,
        error: error,
        context: context
      )
    end

    result
  end

  def self.start_trace(name, metadata: {}, context: {})
    Span.new(name: name, metadata: metadata, context: context)
  end

  class Span
    def initialize(name:, metadata: {}, context: {})
      @name = name
      @metadata = metadata
      @context = context
      @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @finished = false
    end

    def finish(error: nil)
      return if @finished

      @finished = true
      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_time) * 1000.0

      return unless Catpm.enabled? && Catpm.buffer

      Collector.process_custom(
        name: @name,
        duration: duration_ms,
        metadata: @metadata,
        error: error,
        context: @context
      )
    end

    def finished?
      @finished
    end
  end
end
