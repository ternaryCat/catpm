# frozen_string_literal: true

require 'test_helper'

class CircuitBreakerTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_stats!
    @cb = Catpm::CircuitBreaker.new(failure_threshold: 3, recovery_timeout: 0.1)
  end

  test 'starts in closed state' do
    assert_equal :closed, @cb.state
    assert_not @cb.open?
  end

  test 'stays closed under threshold' do
    2.times { @cb.record_failure }
    assert_equal :closed, @cb.state
    assert_not @cb.open?
  end

  test 'opens after reaching failure threshold' do
    3.times { @cb.record_failure }
    assert_equal :open, @cb.state
    assert @cb.open?
    assert_equal 1, Catpm.stats[:circuit_opens]
  end

  test 'blocks while open' do
    3.times { @cb.record_failure }
    assert @cb.open?
  end

  test 'transitions to half_open after recovery timeout' do
    3.times { @cb.record_failure }
    assert @cb.open?

    sleep(0.15) # Wait for recovery timeout
    assert_not @cb.open? # Should transition to half_open
    assert_equal :half_open, @cb.state
  end

  test 'closes on success in half_open' do
    3.times { @cb.record_failure }
    sleep(0.15)
    @cb.open? # Trigger transition to half_open

    @cb.record_success
    assert_equal :closed, @cb.state
    assert_not @cb.open?
  end

  test 're-opens on failure in half_open' do
    3.times { @cb.record_failure }
    sleep(0.15)
    @cb.open? # Trigger transition to half_open

    @cb.record_failure
    # Need to reach threshold again from current failure count
    # But failures accumulate, so one more failure after already having 3 should keep it open
    assert_equal :open, @cb.state
  end

  test 'record_success resets failure count' do
    2.times { @cb.record_failure }
    @cb.record_success
    assert_equal :closed, @cb.state

    # Should need full threshold again
    2.times { @cb.record_failure }
    assert_not @cb.open?
  end

  test 'reset! restores initial state' do
    3.times { @cb.record_failure }
    assert @cb.open?

    @cb.reset!
    assert_equal :closed, @cb.state
    assert_not @cb.open?
  end
end
