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
  end
end
