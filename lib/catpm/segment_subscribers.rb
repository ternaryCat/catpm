# frozen_string_literal: true

module Catpm
  module SegmentSubscribers
    MIN_INSTANTIATION_DURATION_MS = 0.1
    CALLER_OFFSET = 4 # frames to skip to reach user code from this call site
    # Subscriber with start/finish callbacks so all segments (SQL, views, etc.)
    # fired during a controller action are automatically nested under the controller span.
    class ControllerSpanSubscriber
      def start(_name, _id, payload)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        detail = "#{payload[:controller]}##{payload[:action]}"
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        index = req_segments.push_span(type: :controller, detail: detail, started_at: started_at)
        payload[:_catpm_controller_span_index] = index
      end

      def finish(_name, _id, payload)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        req_segments.pop_span(payload[:_catpm_controller_span_index])
      end
    end

    # Subscriber object with start/finish callbacks so SQL queries
    # fired during view rendering are automatically nested under the view span.
    class ViewSpanSubscriber
      def start(_name, _id, payload)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        identifier = payload[:identifier].to_s
        root_slash = Fingerprint.cached_rails_root_slash
        if root_slash
          identifier = identifier.delete_prefix(root_slash)
        end

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        index = req_segments.push_span(type: :view, detail: identifier, started_at: started_at)
        payload[:_catpm_span_index] = index
      end

      def finish(_name, _id, payload)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        req_segments.pop_span(payload[:_catpm_span_index])
      end
    end

    IGNORED_SQL_NAMES = Set.new([
      'SCHEMA', 'EXPLAIN',
      'ActiveRecord::SchemaMigration Load',
      'ActiveRecord::InternalMetadata Load'
    ]).freeze

    class << self
      def subscribe!
        unsubscribe!

        @controller_span_subscriber = ActiveSupport::Notifications.subscribe(
          'process_action.action_controller', ControllerSpanSubscriber.new
        )

        @sql_subscriber = ActiveSupport::Notifications.subscribe(
          'sql.active_record'
        ) do |event|
          record_sql_segment(event)
        end

        @instantiation_subscriber = ActiveSupport::Notifications.subscribe(
          'instantiation.active_record'
        ) do |event|
          record_instantiation_segment(event)
        end

        @render_template_subscriber = ActiveSupport::Notifications.subscribe(
          'render_template.action_view', ViewSpanSubscriber.new
        )

        @render_partial_subscriber = ActiveSupport::Notifications.subscribe(
          'render_partial.action_view', ViewSpanSubscriber.new
        )

        @cache_read_subscriber = ActiveSupport::Notifications.subscribe(
          'cache_read.active_support'
        ) do |event|
          record_cache_segment(event, 'read')
        end

        @cache_write_subscriber = ActiveSupport::Notifications.subscribe(
          'cache_write.active_support'
        ) do |event|
          record_cache_segment(event, 'write')
        end

        if defined?(ActionMailer)
          @mailer_subscriber = ActiveSupport::Notifications.subscribe(
            'deliver.action_mailer'
          ) do |event|
            record_mailer_segment(event)
          end
        end

        if defined?(ActiveStorage)
          @storage_upload_subscriber = ActiveSupport::Notifications.subscribe(
            'service_upload.active_storage'
          ) do |event|
            record_storage_segment(event, 'upload')
          end

          @storage_download_subscriber = ActiveSupport::Notifications.subscribe(
            'service_download.active_storage'
          ) do |event|
            record_storage_segment(event, 'download')
          end
        end
      end

      def unsubscribe!
        [
          @controller_span_subscriber,
          @sql_subscriber, @instantiation_subscriber,
          @render_template_subscriber, @render_partial_subscriber,
          @cache_read_subscriber, @cache_write_subscriber,
          @mailer_subscriber, @storage_upload_subscriber, @storage_download_subscriber
        ].each do |sub|
          ActiveSupport::Notifications.unsubscribe(sub) if sub
        end
        @controller_span_subscriber = nil
        @sql_subscriber = nil
        @instantiation_subscriber = nil
        @render_template_subscriber = nil
        @render_partial_subscriber = nil
        @cache_read_subscriber = nil
        @cache_write_subscriber = nil
        @mailer_subscriber = nil
        @storage_upload_subscriber = nil
        @storage_download_subscriber = nil
      end

      private

      def record_instantiation_segment(event)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        duration = event.duration
        return if duration < MIN_INSTANTIATION_DURATION_MS # skip trivial instantiations

        payload = event.payload
        record_count = payload[:record_count] || 0
        class_name = payload[:class_name] || 'ActiveRecord'
        detail = "#{class_name} x#{record_count}"
        source = duration >= Catpm.config.segment_source_threshold ? extract_source_location : nil

        # Fold into sql summary for cleaner breakdown
        req_segments.add(
          type: :sql, duration: duration, detail: detail,
          source: source, started_at: event.time
        )
      end

      def record_sql_segment(event)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        payload = event.payload
        return if payload[:name].nil? || IGNORED_SQL_NAMES.include?(payload[:name])
        return if payload[:sql].nil?

        duration = event.duration
        sql = payload[:sql].to_s
        max_len = Catpm.config.max_sql_length
        sql = sql.truncate(max_len) if max_len && sql.length > max_len
        source = duration >= Catpm.config.segment_source_threshold ? extract_source_location : nil

        req_segments.add(
          type: :sql, duration: duration, detail: sql,
          source: source, started_at: event.time
        )
      end

      def record_cache_segment(event, operation)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        duration = event.duration
        key = event.payload[:key].to_s
        hit = event.payload[:hit]
        detail = "cache.#{operation} #{key}"
        detail += hit ? ' (hit)' : ' (miss)' if operation == 'read' && !hit.nil?
        source = duration >= Catpm.config.segment_source_threshold ? extract_source_location : nil

        req_segments.add(
          type: :cache, duration: duration, detail: detail,
          source: source, started_at: event.time
        )
      end

      def record_mailer_segment(event)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        payload = event.payload
        mailer = payload[:mailer].to_s
        to = Array(payload[:to]).first.to_s
        detail = to.empty? ? mailer : "#{mailer} to #{to}"
        source = event.duration >= Catpm.config.segment_source_threshold ? extract_source_location : nil

        req_segments.add(
          type: :mailer, duration: event.duration, detail: detail,
          source: source, started_at: event.time
        )
      end

      def record_storage_segment(event, operation)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        payload = event.payload
        key = payload[:key].to_s
        detail = "#{operation} #{key}"
        source = event.duration >= Catpm.config.segment_source_threshold ? extract_source_location : nil

        req_segments.add(
          type: :storage, duration: event.duration, detail: detail,
          source: source, started_at: event.time
        )
      end

      def extract_source_location
        locations = caller_locations(CALLER_OFFSET, Catpm.config.caller_scan_depth)
        locations&.each do |loc|
          path = loc.path.to_s
          if Fingerprint.app_frame?(path)
            return "#{path}:#{loc.lineno}"
          end
        end
        nil
      end
    end
  end
end
