# frozen_string_literal: true

require 'digest'

module Catpm
  module Fingerprint
    # Generates a stable fingerprint for error grouping.
    # Includes kind so the same exception in HTTP vs job = different groups.
    def self.generate(kind:, error_class:, backtrace:)
      normalized = normalize_backtrace(backtrace || [])
      raw = "#{kind}:#{error_class}\n#{normalized}"
      Digest::SHA256.hexdigest(raw)
    end

    def self.normalize_backtrace(backtrace)
      app_frames = backtrace
        .select { |line| app_frame?(line) }
        .first(5)
        .map { |line| strip_line_number(line) }

      # If there are app frames, group by app code (like Sentry)
      return app_frames.join("\n") if app_frames.any?

      # No app frames = error in a gem/library. Group by crash location
      # so the same bug is always one issue regardless of the caller.
      backtrace
        .reject { |line| line.include?('<internal:') }
        .first(3)
        .map { |line| strip_line_number(line) }
        .join("\n")
    end

    # Checks if a backtrace line belongs to the host application (not a gem or stdlib)
    def self.app_frame?(line)
      return false if line.include?('/gems/')
      return false if line.include?('/ruby/')
      return false if line.include?('<internal:')
      return false if line.include?('/catpm/')

      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        return line.start_with?(Rails.root.to_s) if line.start_with?('/')
      end

      line.start_with?('app/') || line.include?('/app/')
    end

    # Strips line numbers: "app/models/user.rb:42:in `validate'" → "app/models/user.rb:in `validate'"
    def self.strip_line_number(line)
      line.sub(/:\d+:in /, ':in ')
    end
  end
end
