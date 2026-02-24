# frozen_string_literal: true

module Catpm
  class SamplesController < ApplicationController
    def show
      @sample = Catpm::Sample.find(params[:id])
      @bucket = @sample.bucket
      @context = @sample.parsed_context
      @segments = @context['segments'] || @context[:segments] || []
      @summary = @context['segment_summary'] || @context[:segment_summary] || {}
      @error_record = if @sample.error_fingerprint.present?
        Catpm::ErrorRecord.find_by(fingerprint: @sample.error_fingerprint)
      end
    end

    def destroy
      sample = Catpm::Sample.find(params[:id])
      bucket = sample.bucket
      sample.destroy
      if request.xhr?
        render json: { deleted: true }
      elsif bucket
        redirect_to catpm.endpoint_path(kind: bucket.kind, target: bucket.target, operation: bucket.operation), notice: 'Sample deleted'
      else
        redirect_to catpm.status_index_path, notice: 'Sample deleted'
      end
    end
  end
end
