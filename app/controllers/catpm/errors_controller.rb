# frozen_string_literal: true

module Catpm
  class ErrorsController < ApplicationController
    def show
      @error = Catpm::ErrorRecord.find(params[:id])
      @contexts = @error.parsed_contexts
    end
  end
end
