# frozen_string_literal: true

module Catpm
  module Collector
    class << self
      def process_action_controller(event)
        return unless Catpm.enabled?

        payload = event.payload
        target = "#{payload[:controller]}##{payload[:action]}"
        return if target.start_with?("Catpm::")
        return if Catpm.config.ignored?(target)

        duration = event.duration # milliseconds
        status = payload[:status] || (payload[:exception] ? 500 : nil)
        context = build_http_context(payload)
        metadata = build_http_metadata(payload)

        req_segments = Thread.current[:catpm_request_segments]
        if req_segments
          segment_data = req_segments.to_h
          context[:segments] = segment_data[:segments]
          context[:segment_summary] = segment_data[:segment_summary]
          context[:segments_capped] = segment_data[:segments_capped]

          segment_data[:segment_summary].each do |k, v|
            metadata[k] = v
          end
        end

        ev = Event.new(
          kind: :http,
          target: target,
          operation: payload[:method] || "GET",
          duration: duration,
          started_at: Time.current,
          status: status,
          context: scrub(context),
          metadata: metadata,
          error_class: payload[:exception]&.first,
          error_message: payload[:exception]&.last,
          backtrace: payload[:exception_object]&.backtrace
        )

        Catpm.buffer&.push(ev)
      end

      def process_active_job(event)
        return unless Catpm.enabled?

        payload = event.payload
        job = payload[:job]
        target = job.class.name
        return if Catpm.config.ignored?(target)

        duration = event.duration
        exception = payload[:exception_object]

        queue_wait = if job.respond_to?(:enqueued_at) && job.enqueued_at
          ((Time.current - job.enqueued_at.to_time) * 1000.0) rescue nil
        end

        context = {
          job_class: target,
          job_id: job.job_id,
          queue: job.queue_name,
          attempts: job.executions
        }

        metadata = { queue_wait: queue_wait }.compact

        ev = Event.new(
          kind: :job,
          target: target,
          operation: job.queue_name,
          duration: duration,
          started_at: Time.current,
          context: context,
          metadata: metadata,
          error_class: exception&.class&.name,
          error_message: exception&.message,
          backtrace: exception&.backtrace
        )

        Catpm.buffer&.push(ev)
      end

      def process_custom(name:, duration:, metadata: {}, error: nil, context: {})
        return unless Catpm.enabled?
        return if Catpm.config.ignored?(name)

        ev = Event.new(
          kind: :custom,
          target: name,
          operation: "",
          duration: duration,
          started_at: Time.current,
          context: context,
          metadata: metadata || {},
          error_class: error&.class&.name,
          error_message: error&.message,
          backtrace: error&.backtrace
        )

        Catpm.buffer&.push(ev)
      end

      private

      def build_http_context(payload)
        {
          method: payload[:method],
          path: payload[:path],
          params: (payload[:params] || {}).except("controller", "action"),
          status: payload[:status]
        }
      end

      def build_http_metadata(payload)
        h = {}
        h[:db_runtime] = payload[:db_runtime] if payload[:db_runtime]
        h[:view_runtime] = payload[:view_runtime] if payload[:view_runtime]
        h
      end

      def scrub(hash)
        parameter_filter.filter(hash)
      end

      def parameter_filter
        @parameter_filter ||= begin
          filters = Rails.application.config.filter_parameters + Catpm.config.additional_filter_parameters
          ActiveSupport::ParameterFilter.new(filters)
        end
      end
    end
  end
end
