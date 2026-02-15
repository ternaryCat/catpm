# frozen_string_literal: true

module Catpm
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
