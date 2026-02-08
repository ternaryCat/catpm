# frozen_string_literal: true

module Catpm
  module Patches
    module NetHttp
      def request(req, body = nil, &block)
        segments = Thread.current[:catpm_request_segments]
        return super unless segments

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = super
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0

        detail = "#{req.method} #{@address}#{req.path} (#{response.code})"
        source = duration >= Catpm.config.segment_source_threshold ? extract_catpm_source : nil

        segments.add(
          type: :http, duration: duration, detail: detail,
          source: source, started_at: start
        )

        response
      end

      private

      def extract_catpm_source
        locations = caller_locations(2, 30)
        locations&.each do |loc|
          path = loc.path.to_s
          if Catpm::Fingerprint.app_frame?(path)
            return "#{path}:#{loc.lineno}"
          end
        end
        nil
      end
    end
  end
end
