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
      end
    end
  end
end
