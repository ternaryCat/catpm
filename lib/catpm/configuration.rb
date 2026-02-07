# frozen_string_literal: true

module Catpm
  class Configuration
    attr_accessor :enabled,
                  :instrument_http,
                  :instrument_jobs,
                  :slow_threshold,
                  :slow_threshold_per_kind,
                  :ignored_targets,
                  :retention_period,
                  :max_buffer_memory,
                  :flush_interval,
                  :flush_jitter,
                  :max_error_contexts,
                  :bucket_sizes,
                  :error_handler,
                  :http_basic_auth_user,
                  :http_basic_auth_password,
                  :access_policy,
                  :additional_filter_parameters

    def initialize
      @enabled = true
      @instrument_http = true
      @instrument_jobs = false
      @slow_threshold = 500 # milliseconds
      @slow_threshold_per_kind = {}
      @ignored_targets = []
      @retention_period = 7.days
      @max_buffer_memory = 32.megabytes
      @flush_interval = 30 # seconds
      @flush_jitter = 5 # ±seconds
      @max_error_contexts = 5
      @bucket_sizes = { recent: 1.minute, medium: 5.minutes, old: 1.hour }
      @error_handler = ->(e) { Rails.logger.error("[catpm] #{e.message}") }
      @http_basic_auth_user = nil
      @http_basic_auth_password = nil
      @access_policy = nil
      @additional_filter_parameters = []
    end

    def slow_threshold_for(kind)
      slow_threshold_per_kind.fetch(kind.to_sym, slow_threshold)
    end

    def ignored?(target)
      ignored_targets.any? do |pattern|
        case pattern
        when Regexp then pattern.match?(target)
        when String
          if pattern.include?("*")
            File.fnmatch(pattern, target)
          else
            pattern == target
          end
        end
      end
    end
  end
end
