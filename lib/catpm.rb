# frozen_string_literal: true

require 'catpm/version'
require 'catpm/configuration'
require 'catpm/event'
require 'catpm/custom_event'
require 'catpm/tdigest'
require 'catpm/errors'
require 'catpm/buffer'
require 'catpm/circuit_breaker'
require 'catpm/adapter'
require 'catpm/fingerprint'
require 'catpm/stack_sampler'
require 'catpm/request_segments'
require 'catpm/call_tracer'
require 'catpm/flusher'
require 'catpm/collector'
require 'catpm/middleware'
require 'catpm/middleware_probe'
require 'catpm/subscribers'
require 'catpm/segment_subscribers'
require 'catpm/lifecycle'
require 'catpm/trace'
require 'catpm/span_helpers'
require 'catpm/auto_instrument'
require 'catpm/engine'

module Catpm
  class << self
    def configure
      yield(config)
    end

    def config
      @config ||= Configuration.new
    end

    def reset_config!
      @config = Configuration.new
      @buffer = nil
      @flusher = nil
    end

    def enabled?
      config.enabled
    end

    attr_writer :buffer, :flusher

    attr_reader :buffer

    attr_reader :flusher

    def stats
      @stats ||= { dropped_events: 0, circuit_opens: 0, flushes: 0 }
    end

    def reset_stats!
      @stats = { dropped_events: 0, circuit_opens: 0, flushes: 0 }
    end

    def event(name, **payload)
      return unless enabled? && config.events_enabled
      buffer&.push(CustomEvent.new(name: name, payload: payload))
    end
  end
end
