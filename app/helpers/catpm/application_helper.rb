# frozen_string_literal: true

module Catpm
  module ApplicationHelper
    # Soft pastel palette — bars, breakdown, waterfall
    SEGMENT_COLORS = {
      'sql' => '#b8e4c6', 'view' => '#e4d4f4', 'cache' => '#fdd8b5',
      'http' => '#f9c4c0', 'mailer' => '#e4d4f4', 'storage' => '#fdd8b5',
      'custom' => '#dde2e8', 'code' => '#c8daf0', 'gem' => '#f0e0f0', 'other' => '#e8e8e8', 'controller' => '#b6d9f7',
      'middleware' => '#f0dfa0', 'request' => '#b6d9f7', 'error' => '#fca5a5'
    }.freeze

    SEGMENT_TEXT_COLORS = {
      'sql' => '#1a7f37', 'view' => '#6639a6', 'cache' => '#953800',
      'http' => '#a1110a', 'mailer' => '#6639a6', 'storage' => '#953800',
      'custom' => '#4b5563', 'code' => '#3b5998', 'gem' => '#7b3f9e', 'other' => '#9ca3af', 'controller' => '#0550ae',
      'middleware' => '#7c5c00', 'request' => '#0550ae', 'error' => '#991b1b'
    }.freeze

    BADGE_CLASSES = {
      'http' => 'badge-http', 'job' => 'badge-job', 'custom' => 'badge-custom',
      'sql' => 'badge-sql', 'view' => 'badge-view', 'cache' => 'badge-cache',
      'mailer' => 'badge-mailer', 'storage' => 'badge-storage',
      'error' => 'badge-error', 'slow' => 'badge-slow', 'random' => 'badge-random'
    }.freeze

    SAMPLE_TYPE_LABELS = {
      'random' => 'sample', 'slow' => 'slow', 'error' => 'error'
    }.freeze

    SEGMENT_LABELS = {
      'sql' => 'SQL Queries', 'view' => 'View Renders', 'cache' => 'Cache Ops',
      'http' => 'HTTP Calls', 'mailer' => 'Mailer', 'storage' => 'Storage',
      'custom' => 'Custom', 'code' => 'App Code', 'gem' => 'Gems', 'other' => 'Untracked',
      'controller' => 'Controller', 'middleware' => 'Middleware', 'request' => 'Request', 'error' => 'Error'
    }.freeze

    RANGES = {
      '1h'  => [1.hour,   60],
      '6h'  => [6.hours,  360],
      '24h' => [24.hours, 1440],
      '1w'  => [1.week,   (1.week / 60).to_i],
      '2w'  => [2.weeks,  (2.weeks / 60).to_i],
      '1m'  => [30.days,  (30.days / 60).to_i],
      '1y'  => [365.days, (365.days / 60).to_i]
    }.freeze

    RANGE_KEYS = RANGES.keys.freeze

    # Setting metadata for the system page — maps config attributes to display info.
    # Ordered by group; Ruby hashes preserve insertion order.
    CONFIG_METADATA = {
      # ── Core ──
      enabled:                          { group: 'Core', label: 'Enabled', desc: 'Master switch for all catpm instrumentation', fmt: :bool },
      track_own_requests:               { group: 'Core', label: 'Track Own Requests', desc: 'Whether catpm dashboard requests are tracked', fmt: :bool },

      # ── Instrumentation ──
      instrument_http:                  { group: 'Instrumentation', label: 'HTTP', desc: 'Capture HTTP request/response metrics via Rack middleware', fmt: :bool },
      instrument_jobs:                  { group: 'Instrumentation', label: 'Jobs', desc: 'Track ActiveJob and Sidekiq background job performance', fmt: :bool },
      instrument_segments:              { group: 'Instrumentation', label: 'Segments', desc: 'Capture SQL, view, cache, and HTTP sub-segments within requests', fmt: :bool },
      instrument_net_http:              { group: 'Instrumentation', label: 'Net::HTTP', desc: 'Patch Net::HTTP to capture outbound HTTP calls as segments', fmt: :bool },
      instrument_middleware_stack:       { group: 'Instrumentation', label: 'Middleware Stack', desc: 'Instrument the full Rack middleware stack for per-middleware timing', fmt: :bool },
      instrument_stack_sampler:         { group: 'Instrumentation', label: 'Stack Sampler', desc: 'Periodically sample the call stack during requests for flame-graph data', fmt: :bool },
      instrument_call_tree:             { group: 'Instrumentation', label: 'Call Tree', desc: 'Capture full method-level call trees within requests', fmt: :bool },
      show_untracked_segments:          { group: 'Instrumentation', label: 'Show Untracked', desc: 'Display time not attributed to any segment in the waterfall view', fmt: :bool },

      # ── Segments ──
      slow_threshold:                   { group: 'Segments', label: 'Slow Threshold', desc: 'Requests slower than this are flagged as slow', fmt: :ms },
      slow_threshold_per_kind:          { group: 'Segments', label: 'Slow Threshold (per kind)', desc: 'Override slow threshold for specific request kinds (http, job, custom)', fmt: :hash_ms },
      max_segments_per_request:         { group: 'Segments', label: 'Max Segments / Request', desc: 'Cap on segments captured per request', fmt: :nullable_int },
      segment_source_threshold:         { group: 'Segments', label: 'Source Capture Threshold', desc: 'Minimum segment duration (ms) before caller_locations is captured; 0 = always', fmt: :ms_zero },
      max_sql_length:                   { group: 'Segments', label: 'Max SQL Length', desc: 'Truncate SQL queries beyond this many characters', fmt: :nullable_chars },
      ignored_targets:                  { group: 'Segments', label: 'Ignored Targets', desc: 'Endpoint patterns excluded from tracking (strings or regexps)', fmt: :list },

      # ── Stack Sampling ──
      stack_sample_interval:            { group: 'Stack Sampling', label: 'Sample Interval', desc: 'How often the call stack is sampled during a request', fmt: :seconds },
      max_stack_samples_per_request:    { group: 'Stack Sampling', label: 'Max Samples / Request', desc: 'Cap on stack samples per request', fmt: :nullable_int },

      # ── Sampling ──
      random_sample_rate:               { group: 'Sampling', label: 'Random Sample Rate', desc: '1-in-N requests are sampled randomly for detailed traces', fmt: :one_in_n },
      max_random_samples_per_endpoint:  { group: 'Sampling', label: 'Max Random / Endpoint', desc: 'Random samples retained per endpoint', fmt: :nullable_int },
      max_slow_samples_per_endpoint:    { group: 'Sampling', label: 'Max Slow / Endpoint', desc: 'Slow samples retained per endpoint', fmt: :nullable_int },
      max_error_samples_per_fingerprint: { group: 'Sampling', label: 'Max Error / Fingerprint', desc: 'Error samples retained per error fingerprint', fmt: :nullable_int },

      # ── Errors ──
      max_error_contexts:               { group: 'Errors', label: 'Max Error Contexts', desc: 'Context snapshots stored per error occurrence', fmt: :nullable_int },
      backtrace_lines:                  { group: 'Errors', label: 'Backtrace Lines', desc: 'Number of backtrace lines captured per error', fmt: :nullable_int },
      max_error_detail_length:          { group: 'Errors', label: 'Max Error Detail Length', desc: 'Truncate error detail segments beyond this length', fmt: :nullable_chars },
      max_fingerprint_app_frames:       { group: 'Errors', label: 'Fingerprint App Frames', desc: 'App stack frames used for error fingerprinting', fmt: :nullable_int },
      max_fingerprint_gem_frames:       { group: 'Errors', label: 'Fingerprint Gem Frames', desc: 'Gem stack frames used when no app frames available', fmt: :nullable_int },

      # ── Events ──
      events_enabled:                   { group: 'Events', label: 'Events Enabled', desc: 'Enable custom event tracking via Catpm.event', fmt: :bool },
      events_max_samples_per_name:      { group: 'Events', label: 'Max Samples / Name', desc: 'Event samples retained per event name', fmt: :nullable_int },

      # ── Buffer & Flush ──
      max_buffer_memory:                { group: 'Buffer & Flush', label: 'Max Buffer Memory', desc: 'Maximum memory for the in-memory event queue before events are dropped', fmt: :bytes },
      flush_interval:                   { group: 'Buffer & Flush', label: 'Flush Interval', desc: 'How often the background thread drains the buffer to the database', fmt: :seconds },
      flush_jitter:                     { group: 'Buffer & Flush', label: 'Flush Jitter', desc: 'Random jitter added to flush interval to avoid thundering herd', fmt: :pm_seconds },
      persistence_batch_size:           { group: 'Buffer & Flush', label: 'Batch Size', desc: 'Number of events written per database transaction', fmt: :int },

      # ── Retention & Downsampling ──
      retention_period:                 { group: 'Retention', label: 'Retention Period', desc: 'How long data is kept; nil = forever (data is downsampled, not deleted)', fmt: :duration },
      cleanup_interval:                 { group: 'Retention', label: 'Cleanup Interval', desc: 'How often the cleanup job runs to remove expired data', fmt: :duration },
      cleanup_batch_size:               { group: 'Retention', label: 'Cleanup Batch Size', desc: 'Rows deleted per cleanup batch', fmt: :nullable_int },
      bucket_sizes:                     { group: 'Retention', label: 'Bucket Sizes', desc: 'Time bucket granularities for data aggregation', fmt: :bucket_sizes },
      downsampling_thresholds:          { group: 'Retention', label: 'Downsampling Thresholds', desc: 'Age before each tier is merged into the next coarser tier', fmt: :downsampling },

      # ── Resilience ──
      circuit_breaker_failure_threshold: { group: 'Resilience', label: 'Circuit Breaker Threshold', desc: 'Consecutive DB write failures before the circuit opens', fmt: :int_failures },
      circuit_breaker_recovery_timeout: { group: 'Resilience', label: 'Circuit Breaker Recovery', desc: 'Seconds before retrying after circuit opens', fmt: :seconds },
      sqlite_busy_timeout:              { group: 'Resilience', label: 'SQLite Busy Timeout', desc: 'How long SQLite waits for a lock before raising BUSY', fmt: :ms, condition: :sqlite? },

      # ── Security ──
      http_basic_auth_user:             { group: 'Security', label: 'HTTP Basic Auth User', desc: 'Username for HTTP Basic authentication on the dashboard', fmt: :secret },
      http_basic_auth_password:         { group: 'Security', label: 'HTTP Basic Auth Password', desc: 'Password for HTTP Basic authentication on the dashboard', fmt: :secret },

      # ── PII Filtering ──
      additional_filter_parameters:     { group: 'PII Filtering', label: 'Additional Filter Parameters', desc: 'Extra parameter names to redact from captured data (on top of Rails defaults)', fmt: :list },

      # ── Advanced ──
      shutdown_timeout:                 { group: 'Advanced', label: 'Shutdown Timeout', desc: 'Seconds to wait for buffer flush on application shutdown', fmt: :seconds },
      caller_scan_depth:                { group: 'Advanced', label: 'Caller Scan Depth', desc: 'Max stack frames scanned to find app code for source attribution', fmt: :int },
      auto_instrument_methods:          { group: 'Advanced', label: 'Auto-Instrument Methods', desc: 'Method signatures to automatically instrument (e.g. Worker#process)', fmt: :list },
      service_base_classes:             { group: 'Advanced', label: 'Service Base Classes', desc: 'Base classes for auto-detection of service objects; nil = auto-detect', fmt: :nullable_list },
    }.freeze

    def format_config_value(config, attr, meta)
      value = config.send(attr)
      case meta[:fmt]
      when :bool           then value ? 'true' : 'false'
      when :ms             then "#{value}ms"
      when :ms_zero        then value == 0 || value == 0.0 ? '0 (always)' : "#{value}ms"
      when :seconds        then "#{value}s"
      when :pm_seconds     then "\u00B1#{value}s"
      when :bytes          then number_to_human_size(value)
      when :int            then value.to_s
      when :int_failures   then "#{value} failures"
      when :one_in_n       then "1 in #{value}"
      when :nullable_int   then value.nil? ? 'unlimited' : value.to_s
      when :nullable_chars then value.nil? ? 'unlimited' : "#{value} chars"
      when :list           then value.respond_to?(:any?) && value.any? ? value.map(&:to_s).join(', ') : 'none'
      when :nullable_list  then value.nil? ? 'auto-detect' : value.map(&:to_s).join(', ')
      when :secret         then value.present? ? 'set' : 'not set'
      when :hash_ms        then value.respond_to?(:any?) && value.any? ? value.map { |k, v| "#{k}: #{v}ms" }.join(', ') : 'none'
      when :duration       then format_duration_value(value)
      when :bucket_sizes   then value.map { |k, v| "#{k}: #{humanize_seconds(v)}" }.join(', ')
      when :downsampling   then value.map { |k, v| "#{k}: #{humanize_seconds(v)}" }.join(', ')
      else value.to_s
      end
    end

    def config_condition_met?(meta)
      return true unless meta[:condition]
      case meta[:condition]
      when :sqlite?
        ActiveRecord::Base.connection.adapter_name.downcase.include?('sqlite')
      else
        true
      end
    end

    def segment_colors
      SEGMENT_COLORS
    end

    def segment_labels
      SEGMENT_LABELS
    end

    def segment_text_colors
      SEGMENT_TEXT_COLORS
    end

    def type_badge(type)
      type_str = type.to_s
      display = SAMPLE_TYPE_LABELS[type_str] || type_str
      css = BADGE_CLASSES[type_str] || ''
      %(<span class="badge #{css}">#{ERB::Util.html_escape(display)}</span>).html_safe
    end

    def format_duration(ms)
      ms = ms.to_f
      if ms >= 1000
        '%.2fs' % (ms / 1000.0)
      else
        '%.1fms' % ms
      end
    end

    def status_badge(status_val)
      return '' unless status_val
      s = status_val.to_i
      css = s >= 500 ? 'badge-err' : s >= 400 ? 'badge-warn' : 'badge-ok'
      %(<span class="badge #{css}">#{status_val}</span>).html_safe
    end

    def segment_count_summary(summary)
      return '' if summary.blank?
      parts = SEGMENT_COLORS.keys.filter_map do |type|
        count = (summary["#{type}_count"] || summary[:"#{type}_count"] || 0).to_i
        next if count == 0
        "#{count} #{type}"
      end
      parts.join(', ')
    end

    def sparkline_svg(data_points, width: 120, height: 48, color: '#539bf5', fill: false, labels: nil, time_labels: nil)
      return '' if data_points.blank?
      points = data_points.map(&:to_f)
      max_val = points.max
      max_val = 1.0 if max_val == 0
      step = width.to_f / [points.size - 1, 1].max

      parsed = points.each_with_index.map do |val, i|
        x = (i * step).round(1)
        y = (height - (val / max_val * (height - 4)) - 2).round(1)
        [x, y, val]
      end

      coords_str = parsed.map { |x, y, _| "#{x},#{y}" }

      fill_el = ''
      if fill
        fill_coords = coords_str + ["#{width},#{height}", "0,#{height}"]
        fill_el = %(<polygon points="#{fill_coords.join(" ")}" fill="#{color}" opacity="0.08"/>)
      end

      circles = parsed.map.with_index do |(x, y, val), i|
        label = labels ? labels[i] : val.is_a?(Float) ? ('%.1f' % val) : val
        time_attr = time_labels ? %( data-time="#{time_labels[i]}") : ''
        %(<circle cx="#{x}" cy="#{y}" r="0" data-value="#{label}"#{time_attr} class="sparkline-dot"/>)
      end.join

      capture = %(<rect width="#{width}" height="#{height}" fill="transparent"/>)
      highlight = %(<circle cx="0" cy="0" r="3" fill="#{color}" class="sparkline-highlight" style="display:none"/>)
      vline = %(<line x1="0" y1="0" x2="0" y2="#{height}" stroke="#{color}" stroke-width="0.5" opacity="0.4" class="sparkline-vline" style="display:none"/>)

      %(<svg class="sparkline-chart" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" xmlns="http://www.w3.org/2000/svg" style="display:block">#{capture}#{fill_el}<polyline points="#{coords_str.join(" ")}" fill="none" stroke="#{color}" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>#{circles}#{vline}#{highlight}</svg>).html_safe
    end

    def bar_chart_svg(data_points, width: 600, height: 200, color: 'var(--accent)', time_labels: nil)
      return '' if data_points.blank?
      points = data_points.map(&:to_i)
      max_val = points.max
      max_val = 1 if max_val == 0
      bar_count = points.size
      gap = 2
      bar_width = ((width.to_f - (bar_count - 1) * gap) / bar_count).round(2)
      bar_width = [bar_width, 1].max

      bars = points.each_with_index.map do |val, i|
        x = (i * (bar_width + gap)).round(2)
        bar_h = (val.to_f / max_val * (height - 20)).round(2)
        y = height - bar_h
        time_attr = time_labels ? %( data-time="#{time_labels[i]}") : ''
        rx = [bar_width / 4, 2].min.round(1)
        # Visible bar
        bar = %(<rect x="#{x}" y="#{y}" width="#{bar_width}" height="#{bar_h}" fill="#{color}" rx="#{rx}" ry="#{rx}" opacity="0.85"/>)
        # Invisible hover target (full height)
        hover = %(<rect x="#{x}" y="0" width="#{bar_width}" height="#{height}" fill="transparent" data-value="#{val}"#{time_attr} class="sparkline-dot"/>)
        bar + hover
      end.join

      # Gridlines
      gridlines = [0.25, 0.5, 0.75].map do |pct|
        gy = (height - pct * (height - 20)).round(1)
        %(<line x1="0" y1="#{gy}" x2="#{width}" y2="#{gy}" stroke="var(--border)" stroke-width="0.5" stroke-dasharray="4,3"/>)
      end.join

      svg = %(<svg width="100%" height="#{height}" viewBox="0 0 #{width} #{height}" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg" style="display:block">#{gridlines}#{bars}</svg>)
      max_label = %(<span class="bar-chart-max">#{max_val}</span>)

      %(<div class="bar-chart-wrap">#{svg}#{max_label}</div>).html_safe
    end

    def relative_time(time)
      return '—' unless time
      time = Time.parse(time) if time.is_a?(String)
      diff = (Time.current - time).to_i
      if diff < 60
        'just now'
      elsif diff < 3600
        "#{diff / 60}m ago"
      elsif diff < 86_400
        "#{diff / 3600}h ago"
      elsif diff < 172_800
        'yesterday'
      elsif diff < 604_800
        "#{diff / 86_400}d ago"
      else
        time.strftime('%b %-d')
      end
    rescue ArgumentError, TypeError
      '—'
    end

    def time_with_tooltip(time)
      return '—' unless time
      time = Time.parse(time) if time.is_a?(String)
      full = time.strftime('%Y-%m-%d %H:%M:%S')
      rel = relative_time(time)
      %(<span title="#{full}" class="time-rel">#{rel}</span>).html_safe
    rescue ArgumentError, TypeError
      '—'
    end

    def sort_header(label, column, current_sort, current_dir, extra_params: {})
      active = current_sort == column.to_s
      new_dir = active && current_dir == 'asc' ? 'desc' : 'asc'
      arrow = active ? (current_dir == 'asc' ? ' &#9650;' : ' &#9660;') : ''
      params_hash = extra_params.merge(sort: column, dir: new_dir)
      url = '?' + params_hash.map { |k, v| "#{k}=#{v}" }.join('&')
      %(<a href="#{url}" class="sort-link#{active ? ' active' : ''}">#{label}#{arrow}</a>).html_safe
    end

    def section_description(text)
      %(<p class="section-desc">#{text}</p>).html_safe
    end

    def status_dot(resolved)
      color = resolved ? 'var(--green)' : 'var(--red)'
      label = resolved ? 'Resolved' : 'Active'
      %(<span class="status-dot"><span class="dot" style="background:#{color}"></span> #{label}</span>).html_safe
    end

    def parse_range(range_str)
      key = (RANGE_KEYS + ['all']).include?(range_str) ? range_str : 'all'
      return [key, nil, nil] if key == 'all'
      period, bucket_seconds = RANGES[key]
      [key, period, bucket_seconds]
    end

    def range_label(range)
      case range
      when 'all' then 'All time'
      when '6h'  then 'Last 6 hours'
      when '24h' then 'Last 24 hours'
      when '1w'  then 'Last week'
      when '2w'  then 'Last 2 weeks'
      when '1m'  then 'Last month'
      when '1y'  then 'Last year'
      else 'Last hour'
      end
    end

    def compute_bucket_seconds(buckets)
      return 60 if buckets.empty?
      times = buckets.map { |b| b.bucket_start.to_i }
      span = times.max - times.min
      span = 3600 if span < 3600
      (span / 60.0).ceil
    end

    def pagination_nav(current_page, total_count, per_page, extra_params: {})
      total_pages = (total_count.to_f / per_page).ceil
      return '' if total_pages <= 1

      prev_params = extra_params.merge(page: current_page - 1)
      next_params = extra_params.merge(page: current_page + 1)
      prev_url = '?' + prev_params.compact.map { |k, v| "#{k}=#{v}" }.join('&')
      next_url = '?' + next_params.compact.map { |k, v| "#{k}=#{v}" }.join('&')

      html = +'<div class="pagination">'
      if current_page > 1
        html << %(<a href="#{prev_url}" class="btn">← Previous</a>)
      else
        html << '<span class="btn" style="opacity:0.3;cursor:default">← Previous</span>'
      end
      html << %(<span class="pagination-info">Page #{current_page} of #{total_pages}</span>)
      if current_page < total_pages
        html << %(<a href="#{next_url}" class="btn">Next →</a>)
      else
        html << '<span class="btn" style="opacity:0.3;cursor:default">Next →</span>'
      end
      html << '</div>'
      html.html_safe
    end

    def trend_indicator(error)
      return '' unless error.last_occurred_at
      if error.last_occurred_at > 1.hour.ago
        %(<span title="Active in the last hour" style="color:var(--red)">↑</span>).html_safe
      else
        %(<span title="Quiet" style="color:var(--text-2)">—</span>).html_safe
      end
    end

    private

    def format_duration_value(value)
      return 'forever' if value.nil?
      secs = value.to_i
      if secs >= 86_400
        "#{secs / 86_400} days"
      elsif secs >= 3600
        "#{secs / 3600} hours"
      else
        "#{secs / 60} min"
      end
    end

    def humanize_seconds(secs)
      secs = secs.to_i
      if secs >= 604_800
        "#{secs / 604_800}w"
      elsif secs >= 86_400
        "#{secs / 86_400}d"
      elsif secs >= 3600
        "#{secs / 3600}h"
      elsif secs >= 60
        "#{secs / 60}min"
      else
        "#{secs}s"
      end
    end
  end
end
