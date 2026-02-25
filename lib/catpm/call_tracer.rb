# frozen_string_literal: true

module Catpm
  class CallTracer
    MAX_CALL_DEPTH = 64

    # Global thread-safe path classification cache — avoids repeated Fingerprint.app_frame? calls
    @global_path_cache = {}
    @global_path_mutex = Mutex.new

    class << self
      def app_frame_cached?(path)
        cached = @global_path_cache[path]
        return cached unless cached.nil?

        result = Fingerprint.app_frame?(path)
        @global_path_mutex.synchronize do
          # Cap cache to prevent unbounded growth across process lifetime
          @global_path_cache.clear if @global_path_cache.size > 2000
          @global_path_cache[path] = result
        end
        result
      end
    end

    def initialize(request_segments:)
      @request_segments = request_segments
      @call_stack = []
      @started = false
      @depth = 0

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
      @depth += 1

      path = tp.path
      app = self.class.app_frame_cached?(path)

      unless app
        @call_stack.push(:skip)
        return
      end

      # Prevent excessive nesting from blowing up memory
      if @depth > MAX_CALL_DEPTH
        @call_stack.push(:skip)
        return
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      detail = format_detail(tp.defined_class, tp.method_id)
      index = @request_segments.push_span(type: :code, detail: detail, started_at: started_at)
      @call_stack.push(index)
    end

    def handle_return
      @depth -= 1 if @depth > 0
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
