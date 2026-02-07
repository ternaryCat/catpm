# frozen_string_literal: true

module Catpm
  class Engine < ::Rails::Engine
    isolate_namespace Catpm

    initializer "catpm.middleware" do |app|
      app.middleware.insert_before 0, Catpm::Middleware
    end

    initializer "catpm.subscribers", after: :load_config_initializers do
      ActiveSupport.on_load(:action_controller) do
        Catpm::Subscribers.subscribe!
      end
    end

    config.after_initialize do
      Catpm::Lifecycle.register_hooks if Catpm.enabled?
    end
  end
end
