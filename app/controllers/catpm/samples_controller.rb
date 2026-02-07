# frozen_string_literal: true

module Catpm
  class SamplesController < ApplicationController
    def show
      @sample = Catpm::Sample.find(params[:id])
      @bucket = @sample.bucket
      @context = @sample.parsed_context
      @segments = @context["segments"] || @context[:segments] || []
      @summary = @context["segment_summary"] || @context[:segment_summary] || {}
    end
  end
end
