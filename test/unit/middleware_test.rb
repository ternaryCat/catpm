# frozen_string_literal: true

require 'test_helper'

class MiddlewareTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
  end

  teardown do
    Catpm.buffer = nil
  end

  test 'sets catpm.request_start in env' do
    app = ->(env) { [200, {}, [env['catpm.request_start'].to_s]] }
    middleware = Catpm::Middleware.new(app)

    status, _headers, body = middleware.call({})
    assert_equal 200, status
    assert body.first.to_f > 0
  end

  test 'passes through when disabled' do
    Catpm.configure { |c| c.enabled = false }

    app = ->(env) { [200, {}, ['OK']] }
    middleware = Catpm::Middleware.new(app)

    env = {}
    middleware.call(env)
    assert_nil env['catpm.request_start']
  end

  test 'captures unhandled exceptions and re-raises' do
    app = ->(_env) { raise RuntimeError, 'unhandled' }
    middleware = Catpm::Middleware.new(app)

    env = {
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => '/boom',
      'action_dispatch.request.path_parameters' => { controller: 'tests', action: 'error' }
    }

    assert_raises(RuntimeError) { middleware.call(env) }

    assert_equal 1, @buffer.size
    ev = @buffer.drain.first
    assert_equal 'http', ev.kind
    assert_equal 'RuntimeError', ev.error_class
    assert_equal 'unhandled', ev.error_message
    assert_equal 500, ev.status
  end

  test 'does not record event for successful requests' do
    app = ->(_env) { [200, {}, ['OK']] }
    middleware = Catpm::Middleware.new(app)

    middleware.call({})
    assert_equal 0, @buffer.size
  end

  # --- MiddlewareProbe tests ---

  test 'middleware probe records span when segments exist' do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    inner_app = ->(env) { [200, {}, ['OK']] }
    probe = Catpm::MiddlewareProbe.new(inner_app, 'ActionDispatch::Executor')

    env = { 'catpm.segments' => req_segments }
    status, _headers, _body = probe.call(env)

    assert_equal 200, status
    segments = req_segments.segments
    assert_equal 1, segments.size
    assert_equal 'middleware', segments[0][:type]
    assert_equal 'ActionDispatch::Executor', segments[0][:detail]
    assert segments[0][:duration] >= 0
  end

  test 'middleware probe passes through when no segments in env' do
    inner_app = ->(env) { [200, {}, ['OK']] }
    probe = Catpm::MiddlewareProbe.new(inner_app, 'ActionDispatch::Executor')

    status, _headers, _body = probe.call({})
    assert_equal 200, status
  end

  test 'middleware probe creates nested spans for chained probes' do
    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    controller_app = ->(env) { [200, {}, ['OK']] }

    # Chain: ProbeB -> ProbeA -> controller
    probe_a = Catpm::MiddlewareProbe.new(controller_app, 'Rack::Sendfile')
    probe_b = Catpm::MiddlewareProbe.new(probe_a, 'ActionDispatch::SSL')

    env = { 'catpm.segments' => req_segments }
    probe_b.call(env)

    segments = req_segments.segments
    assert_equal 2, segments.size
    # ProbeB's span pushed first (index 0), ProbeA pushed inside (index 1)
    assert_equal 'ActionDispatch::SSL', segments[0][:detail]
    assert_equal 'Rack::Sendfile', segments[1][:detail]
    # ProbeA is nested inside ProbeB
    assert_equal 0, segments[1][:parent_index]
  end

  test 'extracts target from action_dispatch params' do
    app = ->(_env) { raise RuntimeError, 'test' }
    middleware = Catpm::Middleware.new(app)

    env = {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/users',
      'action_dispatch.request.path_parameters' => { controller: 'users', action: 'create' }
    }

    assert_raises(RuntimeError) { middleware.call(env) }

    ev = @buffer.drain.first
    assert_equal 'UsersController#create', ev.target
    assert_equal 'POST', ev.operation
  end
end
