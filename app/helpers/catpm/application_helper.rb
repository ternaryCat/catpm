# frozen_string_literal: true

module Catpm
  module ApplicationHelper
    # Soft pastel palette — bars, breakdown, waterfall
    SEGMENT_COLORS = {
      'sql' => '#b8e4c6', 'view' => '#e4d4f4', 'cache' => '#fdd8b5',
      'http' => '#f9c4c0', 'mailer' => '#e4d4f4', 'storage' => '#fdd8b5',
      'custom' => '#dde2e8', 'code' => '#c8daf0', 'gem' => '#f0e0f0', 'other' => '#e8e8e8', 'controller' => '#b6d9f7',
      'middleware' => '#f0dfa0', 'request' => '#b6d9f7'
    }.freeze

    SEGMENT_TEXT_COLORS = {
      'sql' => '#1a7f37', 'view' => '#6639a6', 'cache' => '#953800',
      'http' => '#a1110a', 'mailer' => '#6639a6', 'storage' => '#953800',
      'custom' => '#4b5563', 'code' => '#3b5998', 'gem' => '#7b3f9e', 'other' => '#9ca3af', 'controller' => '#0550ae',
      'middleware' => '#7c5c00', 'request' => '#0550ae'
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
      'controller' => 'Controller', 'middleware' => 'Middleware', 'request' => 'Request'
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
        %(<circle cx="#{x}" cy="#{y}" r="6" fill="transparent" data-value="#{label}"#{time_attr} class="sparkline-dot"/>)
      end.join

      %(<svg width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" xmlns="http://www.w3.org/2000/svg" style="display:block;position:relative">#{fill_el}<polyline points="#{coords_str.join(" ")}" fill="none" stroke="#{color}" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>#{circles}</svg>).html_safe
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

    def parse_range(range_str, extra_valid: [])
      valid = RANGE_KEYS + extra_valid
      key = valid.include?(range_str) ? range_str : '1h'
      return [key, nil, nil] if extra_valid.include?(key) && !RANGES.key?(key)
      period, bucket_seconds = RANGES[key]
      [key, period, bucket_seconds]
    end

    def range_label(range)
      case range
      when '6h'  then 'Last 6 hours'
      when '24h' then 'Last 24 hours'
      when '1w'  then 'Last week'
      when '2w'  then 'Last 2 weeks'
      when '1m'  then 'Last month'
      when '1y'  then 'Last year'
      else 'Last hour'
      end
    end

    def pagination_nav(current_page, total_count, per_page, extra_params: {})
      total_pages = (total_count.to_f / per_page).ceil
      return '' if total_pages <= 1

      prev_params = extra_params.merge(page: current_page - 1)
      next_params = extra_params.merge(page: current_page + 1)
      prev_url = '?' + prev_params.compact.map { |k, v| "#{k}=#{v}" }.join('&')
      next_url = '?' + next_params.compact.map { |k, v| "#{k}=#{v}" }.join('&')

      html = '<div class="pagination">'
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
  end
end
