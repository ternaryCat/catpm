# frozen_string_literal: true

module Catpm
  class CallTracer
    def initialize(request_segments:)
      @request_segments = request_segments
      @call_stack = []
      @path_cache = {}
      @started = false

      @tracepoint = TracePoint.new(:call, :return) do |tp|
        case tp.event
        when :call
          handle_call(tp)
        when :return
          handle_return
        end
      end
    end

    def start
      return if @started

      @started = true
      @tracepoint.enable(target_thread: Thread.current)
    end

    def stop
      return unless @started

      @tracepoint.disable
      @started = false
      flush_remaining_spans
    end

    private

    def handle_call(tp)
      path = tp.path
      app = app_frame?(path)

      unless app
        @call_stack.push(:skip)
        return
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      detail = format_detail(tp.defined_class, tp.method_id)
      index = @request_segments.push_span(type: :code, detail: detail, started_at: started_at)
      @call_stack.push(index)
    end

    def handle_return
      entry = @call_stack.pop
      return if entry == :skip || entry.nil?

      @request_segments.pop_span(entry)
    end

    def flush_remaining_spans
      @call_stack.reverse_each do |entry|
        next if entry == :skip || entry.nil?

        @request_segments.pop_span(entry)
      end
      @call_stack.clear
    end

    def app_frame?(path)
      cached = @path_cache[path]
      return cached unless cached.nil?

      @path_cache[path] = Fingerprint.app_frame?(path)
    end

    def format_detail(defined_class, method_id)
      if defined_class.singleton_class?
        owner = defined_class.attached_object
        "#{owner.name || owner.inspect}.#{method_id}"
      else
        "#{defined_class.name || defined_class.inspect}##{method_id}"
      end
    end
  end
end
