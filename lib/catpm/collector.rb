# frozen_string_literal: true

module Catpm
  module Collector
    class << self
      def process_action_controller(event)
        return unless Catpm.enabled?

        payload = event.payload
        target = "#{payload[:controller]}##{payload[:action]}"
        return if !Catpm.config.track_own_requests && target.start_with?('Catpm::')
        return if Catpm.config.ignored?(target)

        duration = event.duration # milliseconds
        status = payload[:status] || (payload[:exception] ? 500 : nil)
        metadata = build_http_metadata(payload)

        req_segments = Thread.current[:catpm_request_segments]
        if req_segments
          segment_data = req_segments.to_h

          # Total request duration is always needed (includes middleware time)
          total_request_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - req_segments.request_start) * 1000.0
          duration = total_request_duration

          # Segment summary is always needed for bucket metadata aggregation
          segment_data[:segment_summary].each { |k, v| metadata[k] = v }
        end

        # Early sampling decision — only build heavy context for sampled events
        operation = payload[:method] || 'GET'
        sample_type = early_sample_type(
          error: payload[:exception],
          duration: duration,
          kind: :http,
          target: target,
          operation: operation
        )

        if sample_type
          context = build_http_context(payload)

          if req_segments
            segments = segment_data[:segments]

            # Inject root request segment with full duration
            root_segment = {
              type: 'request',
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

            # Inject synthetic middleware segment if there's a time gap before the controller action
            # (only when real per-middleware segments are not present)
            ctrl_idx = segments.index { |s| s[:type] == 'controller' }
            if ctrl_idx
              has_real_middleware = segments.any? { |s| s[:type] == 'middleware' }
              ctrl_offset = (segments[ctrl_idx][:offset] || 0.0).to_f
              if ctrl_offset > 0.5 && !has_real_middleware
                middleware_seg = {
                  type: 'middleware',
                  detail: 'Middleware Stack',
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
                # Add to summary so Time Breakdown shows middleware
                segment_data[:segment_summary][:middleware_count] = 1
                segment_data[:segment_summary][:middleware_duration] = ctrl_offset.round(2)
              end
            end

            # Fill untracked controller time with sampler data or synthetic segment
            ctrl_idx = segments.index { |s| s[:type] == 'controller' }
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
                inject_gap_segments(segments, req_segments, gap, ctrl_idx, ctrl_seg)
              end
            end

            context[:segments] = segments
            context[:segment_summary] = segment_data[:segment_summary]
            context[:segments_capped] = segment_data[:segments_capped]

            # Append error marker segment inside the controller
            if payload[:exception]
              error_parent = ctrl_idx || 0
              error_offset = if ctrl_idx
                ctrl = segments[ctrl_idx]
                ((ctrl[:offset] || 0) + (ctrl[:duration] || 0)).round(2)
              else
                duration.round(2)
              end

              context[:segments] << {
                type: 'error',
                detail: "#{payload[:exception].first}: #{payload[:exception].last}".truncate(200),
                source: payload[:exception_object]&.backtrace&.first,
                duration: 0,
                offset: error_offset,
                parent_index: error_parent
              }
            end
          end

          context = scrub(context)
        end

        ev = Event.new(
          kind: :http,
          target: target,
          operation: operation,
          duration: duration,
          started_at: Time.current,
          status: status,
          context: context,
          sample_type: sample_type,
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

        metadata = { queue_wait: queue_wait }.compact

        sample_type = early_sample_type(
          error: exception,
          duration: duration,
          kind: :job,
          target: target,
          operation: job.queue_name
        )

        context = if sample_type
          {
            job_class: target,
            job_id: job.job_id,
            queue: job.queue_name,
            attempts: job.executions
          }
        end

        ev = Event.new(
          kind: :job,
          target: target,
          operation: job.queue_name,
          duration: duration,
          started_at: Time.current,
          context: context,
          sample_type: sample_type,
          metadata: metadata,
          error_class: exception&.class&.name,
          error_message: exception&.message,
          backtrace: exception&.backtrace
        )

        Catpm.buffer&.push(ev)
      end

      def process_tracked(kind:, target:, operation:, duration:, context:, metadata:, error:, req_segments:)
        return unless Catpm.enabled?
        return if Catpm.config.ignored?(target)

        metadata = (metadata || {}).dup

        if req_segments
          segment_data = req_segments.to_h
          segment_data[:segment_summary]&.each { |k, v| metadata[k] = v }
        end

        sample_type = early_sample_type(
          error: error,
          duration: duration,
          kind: kind,
          target: target,
          operation: operation
        )

        if sample_type
          context = (context || {}).dup

          if req_segments && segment_data
            segments = segment_data[:segments]

            # Inject root request segment
            root_segment = {
              type: 'request',
              detail: "#{operation.presence || kind} #{target}",
              duration: duration.round(2),
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

            # Fill untracked controller time with sampler data or synthetic segment
            ctrl_idx = segments.index { |s| s[:type] == 'controller' }
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
                inject_gap_segments(segments, req_segments, gap, ctrl_idx, ctrl_seg)
              end
            end

            context[:segments] = segments
            context[:segment_summary] = segment_data[:segment_summary]
            context[:segments_capped] = segment_data[:segments_capped]

            # Append error marker segment inside the controller
            if error
              error_parent = ctrl_idx || 0
              error_offset = if ctrl_idx
                ctrl = segments[ctrl_idx]
                ((ctrl[:offset] || 0) + (ctrl[:duration] || 0)).round(2)
              else
                duration.round(2)
              end

              context[:segments] << {
                type: 'error',
                detail: "#{error.class.name}: #{error.message}".truncate(200),
                source: error.backtrace&.first,
                duration: 0,
                offset: error_offset,
                parent_index: error_parent
              }
            end
          end

          context = scrub(context)
        else
          context = nil
        end

        ev = Event.new(
          kind: kind,
          target: target,
          operation: operation.to_s,
          duration: duration,
          started_at: Time.current,
          status: error ? 500 : 200,
          context: context,
          sample_type: sample_type,
          metadata: metadata,
          error_class: error&.class&.name,
          error_message: error&.message,
          backtrace: error&.backtrace
        )

        Catpm.buffer&.push(ev)
      end

      def process_custom(name:, duration:, metadata: {}, error: nil, context: {})
        return unless Catpm.enabled?
        return if Catpm.config.ignored?(name)

        ev = Event.new(
          kind: :custom,
          target: name,
          operation: '',
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

      # Determine sample type at event creation time so only sampled events
      # carry full context in the buffer. Includes filling phase via
      # process-level counter (resets on restart — acceptable approximation).
      def early_sample_type(error:, duration:, kind:, target:, operation:)
        return 'error' if error
        return 'slow' if duration >= Catpm.config.slow_threshold_for(kind.to_sym)

        # Filling phase: always sample until endpoint has enough random samples
        endpoint_key = [kind.to_s, target, operation.to_s]
        count = random_sample_counts[endpoint_key]
        if count < Catpm.config.max_random_samples_per_endpoint
          random_sample_counts[endpoint_key] = count + 1
          return 'random'
        end

        return 'random' if rand(Catpm.config.random_sample_rate) == 0
        nil
      end

      def random_sample_counts
        @random_sample_counts ||= Hash.new(0)
      end

      def inject_gap_segments(segments, req_segments, gap, ctrl_idx, ctrl_seg)
        sampler_groups = req_segments&.sampler_segments || []

        if sampler_groups.any?
          sampler_dur = 0.0

          sampler_groups.each do |group|
            parent = group[:parent]
            children = group[:children] || []

            parent_idx = segments.size
            parent[:parent_index] = ctrl_idx
            segments << parent
            sampler_dur += (parent[:duration] || 0).to_f

            children.each do |child|
              child[:parent_index] = parent_idx
              child[:collapsed] = true
              segments << child
            end
          end

          remaining = gap - sampler_dur
          if remaining > 1.0
            segments << {
              type: 'other',
              detail: 'Untracked',
              duration: remaining.round(2),
              offset: (ctrl_seg[:offset] || 0.0),
              parent_index: ctrl_idx
            }
          end
        else
          segments << {
            type: 'other',
            detail: 'Untracked',
            duration: gap.round(2),
            offset: (ctrl_seg[:offset] || 0.0),
            parent_index: ctrl_idx
          }
        end
      end

      def build_http_context(payload)
        {
          method: payload[:method],
          path: payload[:path],
          params: (payload[:params] || {}).except('controller', 'action'),
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
