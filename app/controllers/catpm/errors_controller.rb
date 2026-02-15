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
