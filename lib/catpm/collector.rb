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
          segments = segment_data[:segments]

          # Compute full request duration from middleware start to now
          # (event.duration only covers the controller action, not middleware)
          total_request_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - req_segments.request_start) * 1000.0

          # Inject root request segment with full duration
          root_segment = {
            type: "request",
            detail: "#{payload[:method]} #{payload[:path]}",
            duration: total_request_duration.round(2),
            offset: 0.0
          }
          segments.each do |seg|
            if seg.key?(:parent_index)
              seg[:parent_index] += 1
            else
              seg[:parent_index] = 0
            end
          end
          segments.unshift(root_segment)

          # Inject middleware segment if there's a time gap before the controller action
          ctrl_idx = segments.index { |s| s[:type] == "controller" }
          if ctrl_idx
            ctrl_offset = (segments[ctrl_idx][:offset] || 0.0).to_f
            if ctrl_offset > 0.5
              middleware_seg = {
                type: "middleware",
                detail: "Middleware Stack",
                duration: ctrl_offset.round(2),
                offset: 0.0,
                parent_index: 0
              }
              segments.insert(1, middleware_seg)
              # Shift parent_index for segments that moved down
              segments.each_with_index do |seg, i|
                next if i <= 1
                next unless seg.key?(:parent_index)
                seg[:parent_index] += 1 if seg[:parent_index] >= 1
              end
            end
          end

          # Inject synthetic "execution" segment for untracked controller time
          ctrl_idx = segments.index { |s| s[:type] == "controller" }
          if ctrl_idx
            ctrl_seg = segments[ctrl_idx]
            ctrl_dur = (ctrl_seg[:duration] || 0).to_f
            child_dur = segments.each_with_index.sum do |pair|
              seg, i = pair
              next 0.0 if i == ctrl_idx
              (seg[:parent_index] == ctrl_idx) ? (seg[:duration] || 0).to_f : 0.0
            end
            gap = ctrl_dur - child_dur
            if gap > 1.0
              segments << {
                type: "code",
                detail: "Controller execution (serialization, callbacks, etc.)",
                duration: gap.round(2),
                offset: (ctrl_seg[:offset] || 0.0),
                parent_index: ctrl_idx
              }
            end
          end

          context[:segments] = segments
          context[:segment_summary] = segment_data[:segment_summary]
          context[:segments_capped] = segment_data[:segments_capped]

          segment_data[:segment_summary].each do |k, v|
            metadata[k] = v
          end

          # Use full request duration (including middleware) for the event
          duration = total_request_duration
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
