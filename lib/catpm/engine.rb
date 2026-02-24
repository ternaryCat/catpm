# frozen_string_literal: true

module Catpm
  class Engine < ::Rails::Engine
    isolate_namespace Catpm

    initializer 'catpm.middleware' do |app|
      app.middleware.insert_before 0, Catpm::Middleware
    end

    config.after_initialize do
      if Catpm.enabled?
        Catpm::Subscribers.subscribe!
        Catpm::Lifecycle.register_hooks
        Catpm::AutoInstrument.apply!

        if Catpm.config.instrument_middleware_stack
          app = Rails.application
          middlewares = app.middleware.reject { |m| m.name&.start_with?('Catpm::') }
          middlewares.reverse_each do |middleware|
            app.middleware.insert_before(middleware, Catpm::MiddlewareProbe, middleware.name)
          rescue ArgumentError, RuntimeError
            # Middleware not found in stack — skip
          end
        end
      end
    end

    config.to_prepare do
      Catpm::AutoInstrument.apply! if Catpm.enabled?
    end
  end
end
