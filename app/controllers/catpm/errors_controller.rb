# frozen_string_literal: true

module Catpm
  class ErrorsController < ApplicationController
    PER_PAGE = 30

    def index
      @tab = params[:tab] == 'resolved' ? 'resolved' : 'active'
      @active_count = Catpm::ErrorRecord.unresolved.count
      @resolved_count = Catpm::ErrorRecord.resolved.count
      @active_error_count = @active_count

      scope = if @tab == 'resolved'
        Catpm::ErrorRecord.resolved
      else
        Catpm::ErrorRecord.unresolved
      end

      @available_kinds = scope.distinct.pluck(:kind).sort

      if params[:kind].present? && @available_kinds.include?(params[:kind])
        @kind_filter = params[:kind]
        scope = scope.where(kind: @kind_filter)
      end

      @sort = %w[error_class occurrences_count last_occurred_at].include?(params[:sort]) ? params[:sort] : 'last_occurred_at'
      @dir = params[:dir] == 'asc' ? 'asc' : 'desc'

      @total_count = scope.count
      @page = [params[:page].to_i, 1].max
      @errors = scope.order(@sort => @dir).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    def show
      @error = Catpm::ErrorRecord.find(params[:id])
      @contexts = @error.parsed_contexts
      @active_error_count = Catpm::ErrorRecord.unresolved.count

      @range, period, bucket_seconds = helpers.parse_range(params[:range] || '24h')

      # Samples table: 20 most recent linked by fingerprint
      @samples = Catpm::Sample.where(error_fingerprint: @error.fingerprint)
                              .order(recorded_at: :desc)
                              .limit(20)

      # Fallback: match error samples by recorded_at from contexts
      if @samples.empty? && @contexts.any?
        occurred_times = @contexts.filter_map { |c|
          Time.parse(c['occurred_at'] || c[:occurred_at]) rescue nil
        }
        if occurred_times.any?
          @samples = Catpm::Sample.where(sample_type: 'error', kind: @error.kind, recorded_at: occurred_times)
                                  .order(recorded_at: :desc)
                                  .limit(20)
        end
      end

      # Chart from occurrence_buckets (multi-resolution, no dependency on samples)
      ob = @error.parsed_occurrence_buckets

      # Pick resolution: minute for short ranges, hour for medium, day for long
      resolution = case @range
                   when '1h', '6h', '24h' then 'm'
                   when '1w', '2w', '1m' then 'h'
                   else 'd'
      end

      slots = {}
      cutoff = period.ago.to_i
      (ob[resolution] || {}).each do |ts_str, count|
        ts = ts_str.to_i
        next if ts < cutoff
        slot_key = (ts / bucket_seconds) * bucket_seconds
        slots[slot_key] = (slots[slot_key] || 0) + count
      end

      now_slot = (Time.current.to_i / bucket_seconds) * bucket_seconds
      @chart_data = 60.times.map { |i| slots[now_slot - (59 - i) * bucket_seconds] || 0 }
      @chart_times = 60.times.map { |i| Time.at(now_slot - (59 - i) * bucket_seconds).strftime('%H:%M') }
    end

    def resolve
      error = Catpm::ErrorRecord.find(params[:id])
      error.resolve!
      redirect_to catpm.error_path(error), notice: 'Marked as resolved'
    end

    def unresolve
      error = Catpm::ErrorRecord.find(params[:id])
      error.unresolve!
      redirect_to catpm.error_path(error), notice: 'Reopened'
    end

    def destroy
      error = Catpm::ErrorRecord.find(params[:id])
      error.destroy!
      redirect_to catpm.errors_path, notice: 'Error deleted'
    end

    def resolve_all
      Catpm::ErrorRecord.unresolved.update_all(resolved_at: Time.current)
      redirect_to catpm.errors_path, notice: 'All errors resolved'
    end
  end
end
