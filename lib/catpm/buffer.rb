# frozen_string_literal: true

module Catpm
  class Buffer
    attr_reader :current_bytes, :dropped_count

    def initialize(max_bytes:)
      @monitor = Monitor.new
      @events = []
      @current_bytes = 0
      @max_bytes = max_bytes
      @dropped_count = 0
    end

    # Called from request threads. Returns :accepted or :dropped.
    # Never blocks — monitoring must not slow down the application.
    def push(event)
      @monitor.synchronize do
        bytes = event.estimated_bytes
        if @current_bytes + bytes > @max_bytes
          @dropped_count += 1
          Catpm.stats[:dropped_events] += 1
          return :dropped
        end

        @events << event
        @current_bytes += bytes
        :accepted
      end
    end

    # Called from flusher thread. Atomically swaps out the entire buffer.
    # Returns the array of events and resets internal state.
    def drain
      @monitor.synchronize do
        events = @events
        @events = []
        @current_bytes = 0
        events
      end
    end

    def size
      @monitor.synchronize { @events.size }
    end

    def empty?
      @monitor.synchronize { @events.empty? }
    end

    def reset!
      @monitor.synchronize do
        @events = []
        @current_bytes = 0
        @dropped_count = 0
      end
    end
  end
end
