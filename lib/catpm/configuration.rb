# frozen_string_literal: true

module Catpm
  class Configuration
    # Boolean / non-numeric settings — plain attr_accessor
    attr_accessor :enabled,
                  :instrument_http,
                  :instrument_jobs,
                  :instrument_segments,
                  :instrument_net_http,
                  :instrument_stack_sampler,
                  :instrument_middleware_stack,
                  :instrument_call_tree,
                  :slow_threshold_per_kind,
                  :ignored_targets,
                  :bucket_sizes,
                  :error_handler,
                  :http_basic_auth_user,
                  :http_basic_auth_password,
                  :access_policy,
                  :additional_filter_parameters,
                  :auto_instrument_methods,
                  :service_base_classes,
                  :events_enabled,
                  :track_own_requests,
                  :downsampling_thresholds,
                  :show_untracked_segments

    # Numeric settings that must be positive numbers (nil not allowed)
    REQUIRED_NUMERIC = %i[
      slow_threshold max_buffer_memory flush_interval flush_jitter
      random_sample_rate cleanup_interval
      circuit_breaker_failure_threshold circuit_breaker_recovery_timeout
      sqlite_busy_timeout persistence_batch_size shutdown_timeout
      stack_sample_interval segment_source_threshold
    ].freeze

    # Numeric settings where nil means "no limit" / "disabled"
    OPTIONAL_NUMERIC = %i[
      max_segments_per_request retention_period backtrace_lines
      max_random_samples_per_endpoint max_slow_samples_per_endpoint
      max_error_samples_per_fingerprint max_sql_length max_error_contexts
      events_max_samples_per_name max_stack_samples_per_request
      max_error_detail_length max_fingerprint_app_frames
      max_fingerprint_gem_frames cleanup_batch_size caller_scan_depth
    ].freeze

    (REQUIRED_NUMERIC + OPTIONAL_NUMERIC).each do |attr|
      attr_reader attr

      define_method(:"#{attr}=") do |value|
        if REQUIRED_NUMERIC.include?(attr)
          unless value.is_a?(Numeric)
            raise ArgumentError, "catpm config.#{attr} must be a number, got #{value.inspect}"
          end
        else
          unless value.nil? || value.is_a?(Numeric)
            raise ArgumentError, "catpm config.#{attr} must be a number or nil, got #{value.inspect}"
          end
        end
        instance_variable_set(:"@#{attr}", value)
      end
    end

    def initialize
      @enabled = true
      @instrument_http = true
      @instrument_jobs = false
      @instrument_segments = true
      @instrument_net_http = false
      @instrument_stack_sampler = false
      @instrument_middleware_stack = false
      @max_segments_per_request = 50
      @segment_source_threshold = 5.0 # ms — capture caller_locations only for segments >= 5ms (set to 0.0 to capture all)
      @max_sql_length = 200
      @slow_threshold = 500 # milliseconds
      @slow_threshold_per_kind = {}
      @ignored_targets = []
      @retention_period = nil # nil = keep forever (data is downsampled, not deleted)
      @max_buffer_memory = 8.megabytes
      @flush_interval = 30 # seconds
      @flush_jitter = 5 # ±seconds
      @max_error_contexts = 5
      @bucket_sizes = { recent: 1.minute, medium: 5.minutes, hourly: 1.hour, daily: 1.day, weekly: 1.week }
      @error_handler = ->(e) { Rails.logger.error("[catpm] #{e.message}") }
      @http_basic_auth_user = nil
      @http_basic_auth_password = nil
      @access_policy = nil
      @additional_filter_parameters = []
      @auto_instrument_methods = []
      @service_base_classes = nil # nil = auto-detect (ApplicationService, BaseService)
      @random_sample_rate = 20
      @max_random_samples_per_endpoint = 5
      @max_slow_samples_per_endpoint = 5
      @max_error_samples_per_fingerprint = 20
      @cleanup_interval = 1.hour
      @circuit_breaker_failure_threshold = 5
      @circuit_breaker_recovery_timeout = 60 # seconds
      @sqlite_busy_timeout = 5_000 # milliseconds
      @persistence_batch_size = 100
      @backtrace_lines = 20 # frames per error backtrace (nil = unlimited)
      @shutdown_timeout = 5 # seconds
      @events_enabled = false
      @events_max_samples_per_name = 20
      @track_own_requests = false
      @stack_sample_interval = 0.005 # seconds (5ms)
      @max_stack_samples_per_request = 200
      @downsampling_thresholds = {
        medium: 1.hour,
        hourly: 24.hours,
        daily: 1.week,
        weekly: 90.days
      }
      @max_error_detail_length = 200
      @max_fingerprint_app_frames = 5
      @max_fingerprint_gem_frames = 3
      @cleanup_batch_size = 1_000
      @caller_scan_depth = 50
      @instrument_call_tree = false
      @show_untracked_segments = false
    end

    def slow_threshold_for(kind)
      slow_threshold_per_kind.fetch(kind.to_sym, slow_threshold)
    end

    def ignored?(target)
      ignored_targets.any? do |pattern|
        case pattern
        when Regexp then pattern.match?(target)
        when String
          if pattern.include?('*')
            File.fnmatch(pattern, target)
          else
            pattern == target
          end
        end
      end
    end
  end
end
