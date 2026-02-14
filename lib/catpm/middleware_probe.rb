# frozen_string_literal: true

module Catpm
  # Lightweight Rack middleware probe inserted before each real middleware
  # when `instrument_middleware_stack` is enabled. Uses push_span/pop_span
  # to create nested spans that capture inclusive time per middleware.
  class MiddlewareProbe
    def initialize(app, middleware_name)
      @app = app
      @middleware_name = middleware_name
    end

    def call(env)
      req_segments = env["catpm.segments"]
      if req_segments
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        idx = req_segments.push_span(type: :middleware, detail: @middleware_name, started_at: started_at)
        begin
          @app.call(env)
        ensure
          req_segments.pop_span(idx)
        end
      else
        @app.call(env)
      end
    end
  end
end
