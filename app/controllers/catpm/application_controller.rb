# frozen_string_literal: true

module Catpm
  class ApplicationController < ActionController::Base
    before_action :authenticate!

    private

    def authenticate!
      if Catpm.config.access_policy
        unless Catpm.config.access_policy.call(request)
          render plain: "Unauthorized", status: :unauthorized
        end
      elsif Catpm.config.http_basic_auth_user.present? && Catpm.config.http_basic_auth_password.present?
        authenticate_or_request_with_http_basic("Catpm") do |username, password|
          ActiveSupport::SecurityUtils.secure_compare(username, Catpm.config.http_basic_auth_user) &
            ActiveSupport::SecurityUtils.secure_compare(password, Catpm.config.http_basic_auth_password)
        end
      end
    end

    def remembered_range
      if params[:range].present?
        cookies[:catpm_range] = { value: params[:range], expires: 1.year.from_now }
      end
      params[:range] || cookies[:catpm_range]
    end
  end
end
