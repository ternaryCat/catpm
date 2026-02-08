# frozen_string_literal: true

module Catpm
  class Engine < ::Rails::Engine
    isolate_namespace Catpm

    initializer "catpm.middleware" do |app|
      app.middleware.insert_before 0, Catpm::Middleware
    end

    config.after_initialize do
      if Catpm.enabled?
        Catpm::Subscribers.subscribe!
        Catpm::Lifecycle.register_hooks
        Catpm::AutoInstrument.apply!
      end
    end

    config.to_prepare do
      Catpm::AutoInstrument.apply! if Catpm.enabled?
    end
  end
end
