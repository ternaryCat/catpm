# frozen_string_literal: true

require 'test_helper'

class EventTest < ActiveSupport::TestCase
  test 'creates event with required fields' do
    event = Catpm::Event.new(kind: :http, target: 'UsersController#index')

    assert_equal 'http', event.kind
    assert_equal 'UsersController#index', event.target
    assert_equal '', event.operation
    assert_equal 0.0, event.duration
    assert_equal({}, event.metadata)
    assert_nil event.error_class
    assert_not event.error?
    assert event.success?
  end

  test 'creates event with all fields' do
    event = Catpm::Event.new(
      kind: :http,
      target: 'UsersController#index',
      operation: 'GET',
      duration: 123.45,
      metadata: { db_runtime: 45.2 },
      status: 200,
      context: { path: '/users' }
    )

    assert_equal 'GET', event.operation
    assert_equal 123.45, event.duration
    assert_equal({ db_runtime: 45.2 }, event.metadata)
    assert_equal 200, event.status
    assert event.success?
  end

  test 'error event' do
    event = Catpm::Event.new(
      kind: :http,
      target: 'UsersController#show',
      error_class: 'ActiveRecord::RecordNotFound',
      error_message: "Couldn't find User with id=999",
      backtrace: ["app/controllers/users_controller.rb:10:in `show'"]
    )

    assert event.error?
    assert_not event.success?
    assert_equal 'ActiveRecord::RecordNotFound', event.error_class
  end

  test 'success? with various status codes' do
    # success? is solely based on error? (presence of error_class), not status code
    assert Catpm::Event.new(kind: :http, target: 't', status: 200).success?
    assert Catpm::Event.new(kind: :http, target: 't', status: 404).success?
    assert Catpm::Event.new(kind: :http, target: 't', status: 500).success?
    assert_not Catpm::Event.new(kind: :http, target: 't', error_class: 'RuntimeError').success?
  end

  test 'operation defaults to empty string for nil' do
    event = Catpm::Event.new(kind: :custom, target: 'test', operation: nil)
    assert_equal '', event.operation
  end

  test 'estimated_bytes returns positive integer' do
    event = Catpm::Event.new(
      kind: :http,
      target: 'UsersController#index',
      operation: 'GET',
      metadata: { db_runtime: 45.2, view_runtime: 12.1 },
      context: { path: '/users', params: { page: 1 } }
    )

    bytes = event.estimated_bytes
    assert_kind_of Numeric, bytes
    assert bytes > 0
    assert bytes > Catpm::Event::OBJECT_OVERHEAD
  end

  test 'estimated_bytes handles minimal event' do
    event = Catpm::Event.new(kind: :http, target: 't')
    bytes = event.estimated_bytes

    assert_kind_of Numeric, bytes
    assert bytes > 0
  end

  test 'estimated_bytes increases with backtrace' do
    small = Catpm::Event.new(kind: :http, target: 't')
    large = Catpm::Event.new(
      kind: :http, target: 't',
      backtrace: Array.new(20) { "app/models/user.rb:#{_1}:in `validate'" }
    )

    assert large.estimated_bytes > small.estimated_bytes
  end

  test 'bucket_start rounds to minute' do
    event = Catpm::Event.new(
      kind: :http, target: 't',
      started_at: Time.new(2025, 6, 1, 12, 34, 56)
    )

    assert_equal Time.new(2025, 6, 1, 12, 34, 0), event.bucket_start
  end
end
