# frozen_string_literal: true

module Catpm
  module SegmentSubscribers
    IGNORED_SQL_NAMES = Set.new([
      "SCHEMA", "EXPLAIN",
      "ActiveRecord::SchemaMigration Load",
      "ActiveRecord::InternalMetadata Load"
    ]).freeze

    class << self
      def subscribe!
        unsubscribe!

        @sql_subscriber = ActiveSupport::Notifications.subscribe(
          "sql.active_record"
        ) do |event|
          record_sql_segment(event)
        end

        @render_template_subscriber = ActiveSupport::Notifications.subscribe(
          "render_template.action_view"
        ) do |event|
          record_view_segment(event)
        end

        @render_partial_subscriber = ActiveSupport::Notifications.subscribe(
          "render_partial.action_view"
        ) do |event|
          record_view_segment(event)
        end
      end

      def unsubscribe!
        [@sql_subscriber, @render_template_subscriber, @render_partial_subscriber].each do |sub|
          ActiveSupport::Notifications.unsubscribe(sub) if sub
        end
        @sql_subscriber = nil
        @render_template_subscriber = nil
        @render_partial_subscriber = nil
      end

      private

      def record_sql_segment(event)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        payload = event.payload
        return if payload[:name].nil? || IGNORED_SQL_NAMES.include?(payload[:name])
        return if payload[:sql].nil?

        duration = event.duration
        sql = payload[:sql].to_s
        max_len = Catpm.config.max_sql_length
        sql = sql[0, max_len] + "..." if sql.length > max_len

        source = duration >= Catpm.config.segment_source_threshold ? extract_source_location : nil

        req_segments.add(type: :sql, duration: duration, detail: sql, source: source)
      end

      def record_view_segment(event)
        req_segments = Thread.current[:catpm_request_segments]
        return unless req_segments

        duration = event.duration
        identifier = event.payload[:identifier].to_s

        if defined?(Rails.root) && identifier.start_with?(Rails.root.to_s)
          identifier = identifier.sub("#{Rails.root}/", "")
        end

        source = duration >= Catpm.config.segment_source_threshold ? extract_source_location : nil

        req_segments.add(type: :view, duration: duration, detail: identifier, source: source)
      end

      def extract_source_location
        locations = caller_locations(4, 30)
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
