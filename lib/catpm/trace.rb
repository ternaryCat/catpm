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

  # Instrument a block as a full request — creates a controller span,
  # collects all segments (SQL, cache, etc.), and pushes a complete Event.
  # Use this for non-ActionController contexts (webhooks, custom endpoints).
  #
  #   Catpm.track_request(kind: :custom, target: "WebhookController#message") do
  #     process_update(...)
  #   end
  #
  def self.track_request(kind: :http, target:, operation: '', context: {}, metadata: {})
    return yield unless enabled?

    req_segments = Thread.current[:catpm_request_segments]
    owns_segments = false

    if req_segments.nil? && config.instrument_segments
      req_segments = RequestSegments.new(
        max_segments: config.max_segments_per_request,
        request_start: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        stack_sample: config.instrument_stack_sampler
      )
      Thread.current[:catpm_request_segments] = req_segments
      owns_segments = true
    end

    if req_segments
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ctrl_idx = req_segments.push_span(type: :controller, detail: target, started_at: started_at)
    end

    error = nil
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      yield
    rescue => e
      error = e
      raise
    ensure
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0
      req_segments&.pop_span(ctrl_idx) if ctrl_idx
      req_segments&.stop_sampler

      Collector.process_tracked(
        kind: kind, target: target, operation: operation,
        duration: duration, context: context, metadata: metadata,
        error: error, req_segments: req_segments
      )

      if owns_segments
        Thread.current[:catpm_request_segments] = nil
      end
    end
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

  CALLER_OFFSET = 3 # frames to skip to reach user code from this call site

  def self.extract_trace_source
    locations = caller_locations(CALLER_OFFSET, Catpm.config.caller_scan_depth)
    locations&.each do |loc|
      path = loc.path.to_s
      if Fingerprint.app_frame?(path)
        return "#{path}:#{loc.lineno}"
      end
    end
    nil
  end
end
