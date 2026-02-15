# frozen_string_literal: true

module Catpm
  class Engine < ::Rails::Engine
    isolate_namespace Catpm

    initializer 'catpm.migrations' do |app|
      config.paths['db/migrate'].expanded.each do |path|
        app.config.paths['db/migrate'] << path unless app.config.paths['db/migrate'].include?(path)
      end
    end

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
          names = app.middleware.filter_map { |m| m.name }.reject { |n| n.start_with?('Catpm::') }
          names.reverse_each do |name|
            app.middleware.insert_before(name, Catpm::MiddlewareProbe, name)
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
