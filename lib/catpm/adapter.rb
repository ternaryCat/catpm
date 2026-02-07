# frozen_string_literal: true

require "catpm/adapter/base"
require "catpm/adapter/sqlite"
require "catpm/adapter/postgresql"

module Catpm
  module Adapter
    def self.current
      @current ||= resolve
    end

    def self.reset!
      @current = nil
    end

    def self.resolve
      adapter_name = ActiveRecord::Base.connection.adapter_name
      case adapter_name
      when /SQLite/i     then Catpm::Adapter::SQLite
      when /PostgreSQL/i then Catpm::Adapter::PostgreSQL
      else
        raise Catpm::UnsupportedAdapter,
          "catpm does not support #{adapter_name}. Supported: PostgreSQL, SQLite."
      end
    end
  end
end
