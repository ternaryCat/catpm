# frozen_string_literal: true

class DemoController < ApplicationController
  def index
    render html: <<~HTML.html_safe
      <h1>catpm Demo</h1>
      <p>Hit these endpoints to generate APM data, then check <a href="/catpm/status">/catpm/status</a></p>
      <ul>
        <li><a href="/demo/fast">Fast request</a> (~5ms)</li>
        <li><a href="/demo/slow">Slow request</a> (~200ms)</li>
        <li><a href="/demo/db_heavy">DB-heavy request</a></li>
        <li><a href="/demo/error">Error request</a> (will show error page)</li>
        <li><a href="/demo/users">Users list</a></li>
        <li><a href="/demo/custom_trace">Custom trace</a></li>
        <li><a href="/demo/flush">Flush buffer to DB</a></li>
      </ul>
      <hr>
      <p><a href="/catpm/status">View collected metrics →</a></p>
    HTML
  end

  def fast
    render plain: 'Done in ~5ms'
  end

  def slow
    sleep(0.2)
    render plain: 'Done in ~200ms (slow)'
  end

  def db_heavy
    # Simulate DB-heavy work
    10.times { Catpm::Bucket.count }
    render plain: 'Done with DB queries'
  end

  def users
    # Simulate a typical CRUD action
    sleep(0.02)
    render plain: 'Users: Alice, Bob, Charlie'
  end

  def error
    raise RuntimeError, 'Something went wrong in DemoController!'
  end

  def custom_trace
    result = Catpm.trace('PaymentProcessing', metadata: { provider: 'stripe', amount: 99.99 }) do
      sleep(0.05)
      'payment_id_123'
    end

    Catpm.trace('EmailDelivery', metadata: { template: 'receipt' }) do
      sleep(0.01)
    end

    span = Catpm.start_trace('WebhookNotification', metadata: { target: 'slack' })
    sleep(0.01)
    span.finish

    render plain: "Custom traces recorded! Payment: #{result}"
  end

  def flush
    if Catpm.flusher
      Catpm.flusher.flush_cycle
      render plain: 'Buffer flushed! Check /catpm/status for results.'
    else
      render plain: 'Flusher not initialized. Make sure catpm is enabled.'
    end
  end
end
