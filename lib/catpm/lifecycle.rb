# frozen_string_literal: true

module Catpm
  module Lifecycle
    class << self
      def register_hooks
        return unless Catpm.enabled?

        initialize_buffer
        initialize_flusher
        apply_patches

        # Start the flusher in the current process.
        # For forking servers (Puma, Passenger, Unicorn, etc.),
        # the middleware detects fork via PID and restarts automatically.
        Catpm.flusher&.start

        register_shutdown_hooks
      end

      def register_shutdown_hooks
        at_exit { Catpm.flusher&.stop }
      end

      private

      def apply_patches
        if Catpm.config.instrument_net_http
          if defined?(::Net::HTTP)
            require 'catpm/patches/net_http'
            ::Net::HTTP.prepend(Catpm::Patches::NetHttp)
          end

          if defined?(::HTTPClient)
            require 'catpm/patches/httpclient'
            ::HTTPClient.prepend(Catpm::Patches::Httpclient)
          end
        end
      end

      def initialize_buffer
        Catpm.buffer ||= Buffer.new(max_bytes: Catpm.config.max_buffer_memory)
      end

      def initialize_flusher
        return unless Catpm.buffer

        Catpm.flusher ||= Flusher.new(
          buffer: Catpm.buffer,
          interval: Catpm.config.flush_interval,
          jitter: Catpm.config.flush_jitter
        )
      end
    end
  end
end
