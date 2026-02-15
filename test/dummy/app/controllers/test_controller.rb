# frozen_string_literal: true

class TestController < ApplicationController
  def index
    render plain: 'OK'
  end

  def slow
    sleep(0.01)
    render plain: 'SLOW'
  end

  def error
    raise RuntimeError, 'boom'
  end
end
