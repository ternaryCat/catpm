# frozen_string_literal: true

module Catpm
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless Catpm.enabled?

      Catpm.flusher&.ensure_running!

      env['catpm.request_start'] = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if Catpm.config.instrument_segments
        use_sampler = Catpm.config.instrument_stack_sampler || Catpm.config.instrument_call_tree
        req_segments = RequestSegments.new(
          max_segments: Catpm.config.max_segments_per_request,
          request_start: env['catpm.request_start'],
          stack_sample: use_sampler,
          call_tree: Catpm.config.instrument_call_tree
        )
        env['catpm.segments'] = req_segments
        Thread.current[:catpm_request_segments] = req_segments
      end

      @app.call(env)
    rescue Exception => e
      record_exception(env, e)
      raise
    ensure
      if Catpm.config.instrument_segments
        req_segments&.stop_sampler
        req_segments&.release!
        Thread.current[:catpm_request_segments] = nil
      end
    end

    private

    def record_exception(env, exception)
      return unless Catpm.buffer

      ev = Event.new(
        kind: :http,
        target: target_from_env(env),
        operation: env['REQUEST_METHOD'] || 'GET',
        duration: elapsed_ms(env),
        started_at: Time.current,
        status: 500,
        sample_type: 'error',
        error_class: exception.class.name,
        error_message: exception.message,
        backtrace: exception.backtrace,
        context: {
          method: env['REQUEST_METHOD'],
          path: env['PATH_INFO']
        }
      )

      Catpm.buffer.push(ev)
    end

    def target_from_env(env)
      if env['action_dispatch.request.path_parameters']
        params = env['action_dispatch.request.path_parameters']
        "#{params[:controller]&.camelize}Controller##{params[:action]}"
      else
        env['PATH_INFO'] || 'unknown'
      end
    end

    def elapsed_ms(env)
      start = env['catpm.request_start']
      return 0.0 unless start

      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0
    end
  end
end
