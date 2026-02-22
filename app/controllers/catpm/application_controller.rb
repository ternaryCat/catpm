# frozen_string_literal: true

module Catpm
  class ApplicationController < ActionController::Base
    private

    def remembered_range
      if params[:range].present?
        cookies[:catpm_range] = { value: params[:range], expires: 1.year.from_now }
      end
      params[:range] || cookies[:catpm_range]
    end
  end
end
