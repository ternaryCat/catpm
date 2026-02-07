# frozen_string_literal: true

module Catpm
  module Lifecycle
    class << self
      def register_hooks
        return unless Catpm.enabled?

        initialize_buffer
        initialize_flusher

        if defined?(::Puma::Plugin)
          register_puma_hook
        elsif defined?(::PhusionPassenger)
          register_passenger_hook
        elsif defined?(::Pitchfork)
          register_pitchfork_hook
        else
          Catpm.flusher&.start
        end

        register_shutdown_hooks
      end

      def register_shutdown_hooks
        at_exit { Catpm.flusher&.stop(timeout: 5) }
      end

      private

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

      def register_puma_hook
        flusher = Catpm.flusher
        ::Puma::Plugin.create do
          events.on_booted { flusher&.start }
        end
      end

      def register_passenger_hook
        flusher = Catpm.flusher
        ::PhusionPassenger.on_event(:starting_worker_process) do |forked|
          flusher&.start if forked
        end
      end

      def register_pitchfork_hook
        flusher = Catpm.flusher
        ::Pitchfork.configure do |server|
          server.after_worker_fork { flusher&.start }
        end
      end
    end
  end
end
