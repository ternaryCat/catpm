# frozen_string_literal: true

module Catpm
  module Collector
    SYNTHETIC_MIDDLEWARE_OFFSET_MS = 0.5
    MIN_GAP_MS = 1.0

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
            collapse_code_wrappers(segments)

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
              if ctrl_offset > SYNTHETIC_MIDDLEWARE_OFFSET_MS && !has_real_middleware
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

            # Inject call tree segments from sampler (replaces TracePoint-based CallTracer)
            ctrl_idx = segments.index { |s| s[:type] == 'controller' }
            if Catpm.config.instrument_call_tree && req_segments
              tree_segs = req_segments.call_tree_segments
              if tree_segs.any?
                base_idx = segments.size
                tree_segs.each do |seg|
                  tree_parent = seg.delete(:_tree_parent)
                  seg[:parent_index] = tree_parent ? (tree_parent + base_idx) : (ctrl_idx || 0)
                  segments << seg
                end
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

              if gap > MIN_GAP_MS && Catpm.config.show_untracked_segments
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
                detail: "#{payload[:exception].first}: #{payload[:exception].last}".truncate(Catpm.config.max_error_detail_length),
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
            collapse_code_wrappers(segments)

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

            # Inject call tree segments from sampler
            ctrl_idx = segments.index { |s| s[:type] == 'controller' }
            if Catpm.config.instrument_call_tree && req_segments
              tree_segs = req_segments.call_tree_segments
              if tree_segs.any?
                base_idx = segments.size
                tree_segs.each do |seg|
                  tree_parent = seg.delete(:_tree_parent)
                  seg[:parent_index] = tree_parent ? (tree_parent + base_idx) : (ctrl_idx || 0)
                  segments << seg
                end
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

              if gap > MIN_GAP_MS && Catpm.config.show_untracked_segments
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
                detail: "#{error.class.name}: #{error.message}".truncate(Catpm.config.max_error_detail_length),
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

      # Remove near-zero-duration "code" spans that merely wrap a "controller" span.
      # This happens when CallTracer (TracePoint) captures a thin dispatch method
      # (e.g. Telegram::WebhookController#process) whose :return fires before the
      # ActiveSupport controller notification finishes.
      # Mutates segments in place: removes the wrapper and re-indexes parent references.
      def collapse_code_wrappers(segments)
        # Pre-build set of parent indices that have a controller child — O(n)
        parents_with_controller = {}
        segments.each do |seg|
          parents_with_controller[seg[:parent_index]] = true if seg[:type] == 'controller' && seg[:parent_index]
        end

        # Identify code spans to collapse: near-zero duration wrapping a controller child
        collapse = {}
        segments.each_with_index do |seg, i|
          next unless seg[:type] == 'code'
          next unless (seg[:duration] || 0).to_f < 1.0
          next unless parents_with_controller[i]

          collapse[i] = seg[:parent_index]
        end

        return if collapse.empty?

        # Reparent children of collapsed spans
        segments.each do |seg|
          pi = seg[:parent_index]
          next unless pi && collapse.key?(pi)
          new_parent = collapse[pi]
          if new_parent.nil?
            seg.delete(:parent_index)
          else
            seg[:parent_index] = new_parent
          end
        end

        # Build old→new index mapping, remove collapsed spans
        old_to_new = {}
        kept = []
        segments.each_with_index do |seg, i|
          next if collapse.key?(i)
          old_to_new[i] = kept.size
          kept << seg
        end

        # Rewrite parent references to new indices
        kept.each do |seg|
          seg[:parent_index] = old_to_new[seg[:parent_index]] if seg[:parent_index]
        end

        segments.replace(kept)
      end

      # Determine sample type at event creation time so only sampled events
      # carry full context in the buffer. Includes filling phase via
      # process-level counter (resets on restart — acceptable approximation).
      def early_sample_type(error:, duration:, kind:, target:, operation:)
        return 'error' if error
        return 'slow' if duration >= Catpm.config.slow_threshold_for(kind.to_sym)

        # Filling phase: always sample until endpoint has enough random samples
        endpoint_key = [kind.to_s, target, operation.to_s]
        count = random_sample_counts[endpoint_key]
        max_random = Catpm.config.max_random_samples_per_endpoint
        if max_random.nil? || count < max_random
          random_sample_counts[endpoint_key] = count + 1
          return 'random'
        end

        return 'random' if rand(Catpm.config.random_sample_rate) == 0
        nil
      end

      def random_sample_counts
        @random_sample_counts ||= Hash.new(0)
      end

      def reset_sample_counts!
        @random_sample_counts = nil
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
          if remaining > MIN_GAP_MS
            inject_timeline_gaps(segments, ctrl_idx, ctrl_seg, remaining)
          end
        else
          inject_timeline_gaps(segments, ctrl_idx, ctrl_seg, gap)
        end
      end

      # Compute actual gap intervals between tracked child segments on the timeline,
      # then create one Untracked entry per gap. This avoids placing a single large
      # Untracked block that overlaps with real segments.
      def inject_timeline_gaps(segments, ctrl_idx, ctrl_seg, total_gap)
        ctrl_offset = (ctrl_seg[:offset] || 0.0).to_f
        ctrl_dur = (ctrl_seg[:duration] || 0.0).to_f
        ctrl_end = ctrl_offset + ctrl_dur

        # Collect [start, end] intervals of direct children that have offsets
        intervals = []
        segments.each_with_index do |seg, i|
          next if i == ctrl_idx
          next unless seg[:parent_index] == ctrl_idx
          off = seg[:offset]
          dur = (seg[:duration] || 0).to_f
          next unless off
          intervals << [off.to_f, off.to_f + dur]
        end

        # If no children have offsets, place the gap at the controller start
        if intervals.empty?
          segments << {
            type: 'other', detail: 'Untracked', duration: total_gap.round(2),
            offset: ctrl_offset, parent_index: ctrl_idx
          }
          return
        end

        # Sort and merge overlapping intervals
        intervals.sort_by!(&:first)
        merged = [intervals.first.dup]
        intervals[1..].each do |s, e|
          if s <= merged.last[1]
            merged.last[1] = e if e > merged.last[1]
          else
            merged << [s, e]
          end
        end

        # Find gaps between controller start, merged intervals, and controller end
        gaps = []
        cursor = ctrl_offset
        merged.each do |s, e|
          gaps << [cursor, s] if s - cursor > 0
          cursor = [cursor, e].max
        end
        gaps << [cursor, ctrl_end] if ctrl_end - cursor > 0

        # Distribute total_gap proportionally across timeline gaps
        raw_gap_sum = gaps.sum { |s, e| e - s }
        return if raw_gap_sum <= 0

        gaps.each do |gs, ge|
          raw_dur = ge - gs
          # Scale so all Untracked segments sum to total_gap
          dur = (raw_dur / raw_gap_sum) * total_gap
          next if dur < MIN_GAP_MS

          segments << {
            type: 'other', detail: 'Untracked', duration: dur.round(2),
            offset: gs.round(2), parent_index: ctrl_idx
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
