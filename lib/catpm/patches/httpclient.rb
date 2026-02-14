# frozen_string_literal: true

module Catpm
  module Patches
    module Httpclient
      def do_get_block(req, proxy, conn, &block)
        segments = Thread.current[:catpm_request_segments]
        return super unless segments

        uri = req.header.request_uri
        http_method = req.header.request_method

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = super
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0

        status = response.status rescue nil
        detail = "#{http_method} #{uri.host}#{uri.path}"
        detail += " (#{status})" if status
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
