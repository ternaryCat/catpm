# frozen_string_literal: true

require 'test_helper'

class ConfigurationTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
  end

  test 'has sensible defaults' do
    config = Catpm.config

    assert_equal true, config.enabled
    assert_equal true, config.instrument_http
    assert_equal false, config.instrument_jobs
    assert_equal 500, config.slow_threshold
    assert_equal({}, config.slow_threshold_per_kind)
    assert_equal [], config.ignored_targets
    assert_nil config.retention_period
    assert_equal 8.megabytes, config.max_buffer_memory
    assert_equal 30, config.flush_interval
    assert_equal 5, config.flush_jitter
    assert_equal 5, config.max_error_contexts
    assert_nil config.http_basic_auth_user
    assert_nil config.http_basic_auth_password
    assert_nil config.access_policy
    assert_equal [], config.additional_filter_parameters
    assert_equal false, config.instrument_net_http
    assert_equal false, config.instrument_middleware_stack
    assert_equal 0.0, config.segment_source_threshold
    assert_equal 20, config.random_sample_rate
    assert_equal 5, config.max_random_samples_per_endpoint
    assert_equal 5, config.max_slow_samples_per_endpoint
    assert_equal 1.hour, config.cleanup_interval
    assert_equal 5, config.circuit_breaker_failure_threshold
    assert_equal 60, config.circuit_breaker_recovery_timeout
    assert_equal 5_000, config.sqlite_busy_timeout
    assert_equal 100, config.persistence_batch_size
    assert_equal 30, config.backtrace_lines
    assert_equal 5, config.shutdown_timeout
  end

  test 'configure block sets values' do
    Catpm.configure do |config|
      config.enabled = false
      config.slow_threshold = 1000
      config.flush_interval = 60
      config.instrument_jobs = true
    end

    assert_equal false, Catpm.config.enabled
    assert_equal 1000, Catpm.config.slow_threshold
    assert_equal 60, Catpm.config.flush_interval
    assert_equal true, Catpm.config.instrument_jobs
  end

  test 'reset_config! restores defaults' do
    Catpm.configure { |c| c.slow_threshold = 9999 }
    assert_equal 9999, Catpm.config.slow_threshold

    Catpm.reset_config!
    assert_equal 500, Catpm.config.slow_threshold
  end

  test 'slow_threshold_for returns kind-specific threshold' do
    Catpm.configure do |c|
      c.slow_threshold = 500
      c.slow_threshold_per_kind = { http: 300, job: 5000 }
    end

    assert_equal 300, Catpm.config.slow_threshold_for(:http)
    assert_equal 5000, Catpm.config.slow_threshold_for(:job)
    assert_equal 500, Catpm.config.slow_threshold_for(:custom) # falls back to default
  end

  test 'ignored? matches exact strings' do
    Catpm.configure { |c| c.ignored_targets = ['HealthcheckController#index'] }

    assert Catpm.config.ignored?('HealthcheckController#index')
    assert_not Catpm.config.ignored?('UsersController#index')
  end

  test 'ignored? matches glob patterns' do
    Catpm.configure { |c| c.ignored_targets = ['/assets/*'] }

    assert Catpm.config.ignored?('/assets/application.css')
    assert Catpm.config.ignored?('/assets/logo.png')
    assert_not Catpm.config.ignored?('/users/1')
  end

  test 'ignored? matches regexps' do
    Catpm.configure { |c| c.ignored_targets = [/health/i] }

    assert Catpm.config.ignored?('HealthcheckController#index')
    assert Catpm.config.ignored?('health_check')
    assert_not Catpm.config.ignored?('UsersController#index')
  end

  test 'enabled? delegates to config' do
    assert Catpm.enabled?

    Catpm.configure { |c| c.enabled = false }
    assert_not Catpm.enabled?
  end
end
