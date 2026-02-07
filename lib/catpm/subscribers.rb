# frozen_string_literal: true

module Catpm
  module Subscribers
    class << self
      def subscribe!
        unsubscribe!

        if Catpm.config.instrument_http
          @http_subscriber = ActiveSupport::Notifications.subscribe(
            "process_action.action_controller"
          ) do |event|
            Collector.process_action_controller(event)
          end
        end

        if Catpm.config.instrument_jobs
          @job_subscriber = ActiveSupport::Notifications.subscribe(
            "perform.active_job"
          ) do |event|
            Collector.process_active_job(event)
          end
        end
      end

      def unsubscribe!
        if @http_subscriber
          ActiveSupport::Notifications.unsubscribe(@http_subscriber)
          @http_subscriber = nil
        end

        if @job_subscriber
          ActiveSupport::Notifications.unsubscribe(@job_subscriber)
          @job_subscriber = nil
        end
      end
    end
  end
end
