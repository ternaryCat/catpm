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
      @flush_callback = nil
    end

    # Register a callback invoked when buffer reaches configured capacity.
    # Used by Flusher to wake up immediately for an emergency flush.
    def on_flush_needed(&block)
      @flush_callback = block
    end

    # Called from request threads. Returns :accepted or :dropped.
    # Never blocks — monitoring must not slow down the application.
    #
    # When buffer reaches max_bytes, signals the flusher for immediate drain
    # and continues accepting events. Only drops as a last resort at 3x capacity
    # (flusher stuck or DB down).
    def push(event)
      signal_flush = false

      @monitor.synchronize do
        bytes = event.estimated_bytes

        # Hard safety cap: 3x configured limit prevents OOM if flusher is stuck
        if @current_bytes + bytes > @max_bytes * 3
          @dropped_count += 1
          Catpm.stats[:dropped_events] += 1
          return :dropped
        end

        @events << event
        @current_bytes += bytes

        signal_flush = @current_bytes >= @max_bytes
      end

      # Signal outside monitor to avoid holding the lock during callback
      @flush_callback&.call if signal_flush
      :accepted
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
