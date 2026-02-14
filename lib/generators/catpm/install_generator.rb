# frozen_string_literal: true

require "rails/generators"

module Catpm
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install catpm: copy migrations, create initializer, mount engine"

      def copy_migrations
        rake "catpm:install:migrations"
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/catpm.rb"
      end

      def mount_engine
        route 'mount Catpm::Engine => "/catpm"'
      end

      def show_post_install
        say ""
        say "catpm installed successfully!", :green
        say ""
        say "Next steps:"
        say "  1. Run: rails db:migrate"
        say "  2. Review config/initializers/catpm.rb"
        say "  3. Visit /catpm in your browser"
        say ""
      end
    end
  end
end
