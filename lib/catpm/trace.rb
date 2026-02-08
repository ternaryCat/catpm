# frozen_string_literal: true

module Catpm
  def self.span(name, type: :custom, &block)
    unless enabled?
      return block.call if block
      return nil
    end

    req_segments = Thread.current[:catpm_request_segments]
    unless req_segments
      return trace(name, &block)
    end

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    index = req_segments.push_span(type: type, detail: name, started_at: start_time)

    begin
      block.call
    ensure
      req_segments.pop_span(index)
    end
  end

  def self.trace(name, metadata: {}, context: {}, &block)
    unless enabled?
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

      req_segments = Thread.current[:catpm_request_segments]
      if req_segments
        source = duration_ms >= config.segment_source_threshold ? extract_trace_source : nil
        req_segments.add(
          type: :custom, duration: duration_ms, detail: name,
          source: source, started_at: start_time
        )
      elsif buffer
        Collector.process_custom(
          name: name, duration: duration_ms,
          metadata: metadata, error: error, context: context
        )
      end
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

      req_segments = Thread.current[:catpm_request_segments]
      if req_segments
        source = duration_ms >= Catpm.config.segment_source_threshold ? Catpm.send(:extract_trace_source) : nil
        req_segments.add(
          type: :custom, duration: duration_ms, detail: @name,
          source: source, started_at: @start_time
        )
      elsif Catpm.enabled? && Catpm.buffer
        Collector.process_custom(
          name: @name, duration: duration_ms,
          metadata: @metadata, error: error, context: @context
        )
      end
    end

    def finished?
      @finished
    end
  end

  private

  def self.extract_trace_source
    locations = caller_locations(3, 50)
    locations&.each do |loc|
      path = loc.path.to_s
      if Fingerprint.app_frame?(path)
        return "#{path}:#{loc.lineno}"
      end
    end
    nil
  end

end
