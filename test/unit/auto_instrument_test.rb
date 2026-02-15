# frozen_string_literal: true

require 'test_helper'

# ─── Test fixture: common Rails service pattern ───

class ApplicationService
  def self.call(...)
    new(...).call
  end

  def call
    raise NotImplementedError
  end
end

module AutoInstrumentTestClasses
  class Calculator
    def add(a, b)
      a + b
    end

    def self.version
      '1.0'
    end
  end
end

class AutoInstrumentTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.reset_stats!
    Catpm.configure { |c| c.enabled = true }
    @buffer = Catpm::Buffer.new(max_bytes: 10.megabytes)
    Catpm.buffer = @buffer
    Catpm::AutoInstrument.reset!
  end

  teardown do
    Thread.current[:catpm_request_segments] = nil
    Catpm.buffer = nil
    Catpm::AutoInstrument.reset!
  end

  # ─── Auto-detect service base classes ───

  test 'auto-detects ApplicationService and instruments .call on subclasses' do
    service_class = Class.new(ApplicationService) do
      def call
        42
      end
    end
    AutoInstrumentTestClasses.const_set(:TestService, service_class)

    Catpm::AutoInstrument.apply!

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = AutoInstrumentTestClasses::TestService.call

    assert_equal 42, result
    assert_equal 1, req_segments.segments.size
    assert_equal 'AutoInstrumentTestClasses::TestService#call', req_segments.segments.first[:detail]
  ensure
    AutoInstrumentTestClasses.send(:remove_const, :TestService) if AutoInstrumentTestClasses.const_defined?(:TestService)
  end

  test 'auto-detected service nests SQL under the service span' do
    service_class = Class.new(ApplicationService) do
      def call
        req = Thread.current[:catpm_request_segments]
        req.add(type: :sql, duration: 5.0, detail: 'SELECT * FROM users') if req
        'done'
      end
    end
    AutoInstrumentTestClasses.const_set(:SqlService, service_class)

    Catpm::AutoInstrument.apply!

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    AutoInstrumentTestClasses::SqlService.call

    assert_equal 2, req_segments.segments.size
    assert_equal 'code', req_segments.segments[0][:type]
    assert_equal 'AutoInstrumentTestClasses::SqlService#call', req_segments.segments[0][:detail]
    assert_equal 'sql', req_segments.segments[1][:type]
    assert_equal 0, req_segments.segments[1][:parent_index], 'SQL should be nested under service span'
  ensure
    AutoInstrumentTestClasses.send(:remove_const, :SqlService) if AutoInstrumentTestClasses.const_defined?(:SqlService)
  end

  test 'auto-detected service works outside request context (falls back to trace)' do
    service_class = Class.new(ApplicationService) do
      def call
        99
      end
    end
    AutoInstrumentTestClasses.const_set(:StandaloneService, service_class)

    Catpm::AutoInstrument.apply!

    result = AutoInstrumentTestClasses::StandaloneService.call

    assert_equal 99, result
    assert_equal 1, @buffer.size
    assert_includes @buffer.drain.first.target, 'StandaloneService#call'
  ensure
    AutoInstrumentTestClasses.send(:remove_const, :StandaloneService) if AutoInstrumentTestClasses.const_defined?(:StandaloneService)
  end

  test "skips base classes that don't exist" do
    Catpm.configure { |c| c.service_base_classes = ['NonExistentBaseService'] }
    assert_nothing_raised { Catpm::AutoInstrument.apply! }
  end

  test 'custom service_base_classes config overrides defaults' do
    custom_base = Class.new do
      def self.call(...)
        new(...).call
      end

      def call
        raise NotImplementedError
      end
    end
    AutoInstrumentTestClasses.const_set(:CustomBase, custom_base)

    child = Class.new(custom_base) do
      def call
        'custom'
      end
    end
    AutoInstrumentTestClasses.const_set(:CustomChild, child)

    Catpm.configure { |c| c.service_base_classes = ['AutoInstrumentTestClasses::CustomBase'] }
    Catpm::AutoInstrument.apply!

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = AutoInstrumentTestClasses::CustomChild.call
    assert_equal 'custom', result
    assert_equal 1, req_segments.segments.size
    assert_equal 'AutoInstrumentTestClasses::CustomChild#call', req_segments.segments.first[:detail]
  ensure
    AutoInstrumentTestClasses.send(:remove_const, :CustomChild) if AutoInstrumentTestClasses.const_defined?(:CustomChild)
    AutoInstrumentTestClasses.send(:remove_const, :CustomBase) if AutoInstrumentTestClasses.const_defined?(:CustomBase)
  end

  # ─── Explicit method list ───

  test 'explicit auto_instrument_methods instruments instance method' do
    Catpm.configure do |c|
      c.auto_instrument_methods = ['AutoInstrumentTestClasses::Calculator#add']
    end
    Catpm::AutoInstrument.apply!

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = AutoInstrumentTestClasses::Calculator.new.add(2, 3)

    assert_equal 5, result
    assert_equal 1, req_segments.segments.size
    assert_equal 'AutoInstrumentTestClasses::Calculator#add', req_segments.segments.first[:detail]
  end

  test 'explicit auto_instrument_methods instruments class method' do
    Catpm.configure do |c|
      c.auto_instrument_methods = ['AutoInstrumentTestClasses::Calculator.version']
    end
    Catpm::AutoInstrument.apply!

    req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = req_segments

    result = AutoInstrumentTestClasses::Calculator.version

    assert_equal '1.0', result
    assert_equal 1, req_segments.segments.size
    assert_equal 'AutoInstrumentTestClasses::Calculator.version', req_segments.segments.first[:detail]
  end

  test 'skips unknown classes in explicit list without error' do
    Catpm.configure do |c|
      c.auto_instrument_methods = ['NonExistent::Class#method']
    end

    assert_nothing_raised { Catpm::AutoInstrument.apply! }
  end

  test 'empty config is a no-op' do
    Catpm.configure { |c| c.auto_instrument_methods = [] }
    assert_nothing_raised { Catpm::AutoInstrument.apply! }
  end
end
