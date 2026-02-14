# frozen_string_literal: true

module Catpm
  class CircuitBreaker
    attr_reader :state

    def initialize(failure_threshold: Catpm.config.circuit_breaker_failure_threshold, recovery_timeout: Catpm.config.circuit_breaker_recovery_timeout)
      @failure_threshold = failure_threshold
      @recovery_timeout = recovery_timeout
      @failures = 0
      @state = :closed
      @opened_at = nil
      @mutex = Mutex.new
    end

    def open?
      @mutex.synchronize do
        case @state
        when :closed
          false
        when :open
          if Time.now - @opened_at >= @recovery_timeout
            @state = :half_open
            false # Allow one probe attempt
          else
            true
          end
        when :half_open
          false
        end
      end
    end

    def record_success
      @mutex.synchronize do
        @failures = 0
        @state = :closed
      end
    end

    def record_failure
      @mutex.synchronize do
        @failures += 1
        if @failures >= @failure_threshold
          @state = :open
          @opened_at = Time.now
          Catpm.stats[:circuit_opens] += 1
        end
      end
    end

    def reset!
      @mutex.synchronize do
        @failures = 0
        @state = :closed
        @opened_at = nil
      end
    end
  end
end
