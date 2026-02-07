# frozen_string_literal: true

require "test_helper"

class LifecycleTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
  end

  teardown do
    Catpm.flusher&.stop(timeout: 1)
    Catpm.buffer = nil
    Catpm.flusher = nil
  end

  test "register_hooks initializes buffer and flusher" do
    assert_nil Catpm.buffer
    assert_nil Catpm.flusher

    Catpm::Lifecycle.register_hooks

    assert_not_nil Catpm.buffer
    assert_instance_of Catpm::Buffer, Catpm.buffer
    assert_not_nil Catpm.flusher
    assert_instance_of Catpm::Flusher, Catpm.flusher
  end

  test "register_hooks starts flusher (fallback mode)" do
    Catpm::Lifecycle.register_hooks

    assert Catpm.flusher.running
  end

  test "register_hooks is no-op when disabled" do
    Catpm.configure { |c| c.enabled = false }

    Catpm::Lifecycle.register_hooks

    assert_nil Catpm.buffer
    assert_nil Catpm.flusher
  end

  test "register_hooks does not overwrite existing buffer" do
    existing_buffer = Catpm::Buffer.new(max_bytes: 1.megabyte)
    Catpm.buffer = existing_buffer

    Catpm::Lifecycle.register_hooks

    assert_equal existing_buffer, Catpm.buffer
  end
end
