# frozen_string_literal: true

require 'digest'

module Catpm
  module Fingerprint
    @path_cache = {}
    @path_cache_mutex = Mutex.new

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
        .first(Catpm.config.max_fingerprint_app_frames)
        .map { |line| strip_line_number(line) }

      # If there are app frames, group by app code (like Sentry)
      return app_frames.join("\n") if app_frames.any?

      # No app frames = error in a gem/library. Group by crash location
      # so the same bug is always one issue regardless of the caller.
      backtrace
        .reject { |line| line.include?('<internal:') }
        .first(Catpm.config.max_fingerprint_gem_frames)
        .map { |line| strip_line_number(line) }
        .join("\n")
    end

    # Cached wrapper — all callers benefit from the shared path cache.
    def self.app_frame?(line)
      cached = @path_cache[line]
      return cached unless cached.nil?

      result = _app_frame?(line)
      @path_cache_mutex.synchronize do
        @path_cache.clear if @path_cache.size > 4000
        @path_cache[line] = result
      end
      result
    end

    # Cached Rails.root.to_s — computed once, never changes after boot.
    def self.cached_rails_root
      return @cached_rails_root if defined?(@cached_rails_root)

      @cached_rails_root = if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s.freeze
      end
    end

    # Cached "#{Rails.root}/" for path stripping.
    def self.cached_rails_root_slash
      return @cached_rails_root_slash if defined?(@cached_rails_root_slash)

      root = cached_rails_root
      @cached_rails_root_slash = root ? "#{root}/".freeze : nil
    end

    def self.reset_caches!
      @path_cache_mutex.synchronize { @path_cache.clear }
      remove_instance_variable(:@cached_rails_root) if defined?(@cached_rails_root)
      remove_instance_variable(:@cached_rails_root_slash) if defined?(@cached_rails_root_slash)
    end

    # Strips line numbers: "app/models/user.rb:42:in `validate'" → "app/models/user.rb:in `validate'"
    def self.strip_line_number(line)
      line.sub(/:\d+:in /, ':in ')
    end

    # The actual classification logic (uncached).
    def self._app_frame?(line)
      return false if line.include?('/gems/')
      return false if line.include?('/ruby/')
      return false if line.include?('<internal:')
      return false if line.include?('/catpm/')

      if (root = cached_rails_root)
        return line.start_with?(root) if line.start_with?('/')
      end

      line.start_with?('app/') || line.include?('/app/')
    end
    private_class_method :_app_frame?
  end
end
