# frozen_string_literal: true

require "test_helper"
require "ostruct"

class SegmentSubscribersTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.configure { |c| c.enabled = true; c.instrument_segments = true }
    @req_segments = Catpm::RequestSegments.new(max_segments: 50)
    Thread.current[:catpm_request_segments] = @req_segments
  end

  teardown do
    Thread.current[:catpm_request_segments] = nil
    Catpm::SegmentSubscribers.unsubscribe!
  end

  test "record_sql_segment is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    event = mock_sql_event(name: "User Load", sql: "SELECT * FROM users", duration: 5.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    # No crash, no segments
    assert_equal 0, @req_segments.segments.size
  end

  test "record_sql_segment adds sql segment" do
    event = mock_sql_event(name: "User Load", sql: "SELECT * FROM users", duration: 5.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert_equal 1, @req_segments.segments.size
    seg = @req_segments.segments.first
    assert_equal "sql", seg[:type]
    assert_equal 5.0, seg[:duration]
    assert_equal "SELECT * FROM users", seg[:detail]
  end

  test "record_sql_segment stores full SQL text" do
    long_sql = "SELECT * FROM users WHERE name = 'very long query here that goes on and on'"
    event = mock_sql_event(name: "User Load", sql: long_sql, duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert_equal long_sql, @req_segments.segments.first[:detail]
  end

  test "record_sql_segment ignores SCHEMA queries" do
    event = mock_sql_event(name: "SCHEMA", sql: "SELECT * FROM sqlite_master", duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert_equal 0, @req_segments.segments.size
  end

  test "record_sql_segment ignores migration queries" do
    event = mock_sql_event(name: "ActiveRecord::SchemaMigration Load", sql: "SELECT *", duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    assert_equal 0, @req_segments.segments.size
  end

  test "record_sql_segment captures source for slow queries" do
    Catpm.configure { |c| c.segment_source_threshold = 0.0 } # capture all
    event = mock_sql_event(name: "User Load", sql: "SELECT 1", duration: 10.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    # Source might be nil if no app frames in the test callstack, but it shouldn't crash
    assert_equal 1, @req_segments.segments.size
  end

  test "record_sql_segment skips source for fast queries" do
    Catpm.configure { |c| c.segment_source_threshold = 100.0 } # very high threshold
    event = mock_sql_event(name: "User Load", sql: "SELECT 1", duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, event)

    refute @req_segments.segments.first.key?(:source)
  end

  # ─── Controller span subscriber ───

  test "controller span subscriber creates controller span and nests inner segments" do
    subscriber = Catpm::SegmentSubscribers::ControllerSpanSubscriber.new
    payload = { controller: "UsersController", action: "index" }

    subscriber.start("process_action.action_controller", "abc123", payload)

    # SQL fired during controller action should be nested
    sql_event = mock_sql_event(name: "User Load", sql: "SELECT * FROM users", duration: 2.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, sql_event)

    subscriber.finish("process_action.action_controller", "abc123", payload)

    assert_equal 2, @req_segments.segments.size
    ctrl_seg = @req_segments.segments[0]
    sql_seg = @req_segments.segments[1]

    assert_equal "controller", ctrl_seg[:type]
    assert_equal "UsersController#index", ctrl_seg[:detail]
    assert ctrl_seg[:duration] >= 0

    assert_equal "sql", sql_seg[:type]
    assert_equal 0, sql_seg[:parent_index], "SQL should be nested under controller span"
  end

  test "controller span subscriber is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    subscriber = Catpm::SegmentSubscribers::ControllerSpanSubscriber.new
    payload = { controller: "UsersController", action: "index" }

    subscriber.start("process_action.action_controller", "abc123", payload)
    subscriber.finish("process_action.action_controller", "abc123", payload)

    assert_equal 0, @req_segments.segments.size
  end

  test "controller span nests view spans which nest SQL" do
    ctrl_sub = Catpm::SegmentSubscribers::ControllerSpanSubscriber.new
    view_sub = Catpm::SegmentSubscribers::ViewSpanSubscriber.new

    ctrl_payload = { controller: "UsersController", action: "index" }
    ctrl_sub.start("process_action.action_controller", "c1", ctrl_payload)

    view_payload = { identifier: "app/views/users/index.html.erb" }
    view_sub.start("render_template.action_view", "v1", view_payload)

    sql_event = mock_sql_event(name: "User Load", sql: "SELECT * FROM users", duration: 3.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, sql_event)

    view_sub.finish("render_template.action_view", "v1", view_payload)
    ctrl_sub.finish("process_action.action_controller", "c1", ctrl_payload)

    assert_equal 3, @req_segments.segments.size

    ctrl_seg = @req_segments.segments[0]  # controller
    view_seg = @req_segments.segments[1]  # view
    sql_seg = @req_segments.segments[2]   # sql

    assert_equal "controller", ctrl_seg[:type]
    refute ctrl_seg.key?(:parent_index)

    assert_equal "view", view_seg[:type]
    assert_equal 0, view_seg[:parent_index], "View should be child of controller"

    assert_equal "sql", sql_seg[:type]
    assert_equal 1, sql_seg[:parent_index], "SQL should be child of view"
  end

  # ─── View span subscriber ───

  test "view span subscriber creates view span and nests inner segments" do
    subscriber = Catpm::SegmentSubscribers::ViewSpanSubscriber.new
    payload = { identifier: "app/views/users/index.html.erb" }

    subscriber.start("render_template.action_view", "abc123", payload)

    # SQL fired during view rendering should be nested
    sql_event = mock_sql_event(name: "User Load", sql: "SELECT * FROM users", duration: 2.0)
    Catpm::SegmentSubscribers.send(:record_sql_segment, sql_event)

    subscriber.finish("render_template.action_view", "abc123", payload)

    assert_equal 2, @req_segments.segments.size
    view_seg = @req_segments.segments[0]
    sql_seg = @req_segments.segments[1]

    assert_equal "view", view_seg[:type]
    assert_includes view_seg[:detail], "users/index"
    assert view_seg[:duration] >= 0

    assert_equal "sql", sql_seg[:type]
    assert_equal 0, sql_seg[:parent_index], "SQL should be nested under view span"
  end

  test "view span subscriber strips Rails.root from identifier" do
    subscriber = Catpm::SegmentSubscribers::ViewSpanSubscriber.new
    full_path = "#{Rails.root}/app/views/users/show.html.erb"
    payload = { identifier: full_path }

    subscriber.start("render_template.action_view", "abc123", payload)
    subscriber.finish("render_template.action_view", "abc123", payload)

    assert_equal "app/views/users/show.html.erb", @req_segments.segments.first[:detail]
  end

  test "view span subscriber is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    subscriber = Catpm::SegmentSubscribers::ViewSpanSubscriber.new
    payload = { identifier: "app/views/test.html.erb" }

    subscriber.start("render_template.action_view", "abc123", payload)
    subscriber.finish("render_template.action_view", "abc123", payload)

    assert_equal 0, @req_segments.segments.size
  end

  test "record_cache_segment adds cache read segment" do
    event = mock_cache_event(key: "users/1", hit: true, duration: 0.5)
    Catpm::SegmentSubscribers.send(:record_cache_segment, event, "read")

    assert_equal 1, @req_segments.segments.size
    seg = @req_segments.segments.first
    assert_equal "cache", seg[:type]
    assert_equal 0.5, seg[:duration]
    assert_includes seg[:detail], "cache.read"
    assert_includes seg[:detail], "users/1"
    assert_includes seg[:detail], "(hit)"
  end

  test "record_cache_segment shows miss for read" do
    event = mock_cache_event(key: "users/2", hit: false, duration: 0.3)
    Catpm::SegmentSubscribers.send(:record_cache_segment, event, "read")

    assert_includes @req_segments.segments.first[:detail], "(miss)"
  end

  test "record_cache_segment adds cache write segment" do
    event = mock_cache_event(key: "users/1", duration: 0.8)
    Catpm::SegmentSubscribers.send(:record_cache_segment, event, "write")

    seg = @req_segments.segments.first
    assert_equal "cache", seg[:type]
    assert_includes seg[:detail], "cache.write"
    refute_includes seg[:detail], "(hit)"
    refute_includes seg[:detail], "(miss)"
  end

  test "record_cache_segment is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    event = mock_cache_event(key: "test", duration: 0.1)
    Catpm::SegmentSubscribers.send(:record_cache_segment, event, "read")

    assert_equal 0, @req_segments.segments.size
  end

  test "record_cache_segment updates summary" do
    event = mock_cache_event(key: "k", hit: true, duration: 1.0)
    Catpm::SegmentSubscribers.send(:record_cache_segment, event, "read")

    assert_equal 1, @req_segments.summary[:cache_count]
    assert_in_delta 1.0, @req_segments.summary[:cache_duration], 0.01
  end

  # ─── Mailer segments (Tier 1) ───

  test "record_mailer_segment adds mailer segment" do
    event = mock_mailer_event(mailer: "UserMailer#welcome", to: ["user@example.com"], duration: 45.0)
    Catpm::SegmentSubscribers.send(:record_mailer_segment, event)

    assert_equal 1, @req_segments.segments.size
    seg = @req_segments.segments.first
    assert_equal "mailer", seg[:type]
    assert_equal 45.0, seg[:duration]
    assert_includes seg[:detail], "UserMailer#welcome"
    assert_includes seg[:detail], "user@example.com"
  end

  test "record_mailer_segment handles missing to" do
    event = mock_mailer_event(mailer: "UserMailer#welcome", to: [], duration: 10.0)
    Catpm::SegmentSubscribers.send(:record_mailer_segment, event)

    assert_equal "UserMailer#welcome", @req_segments.segments.first[:detail]
  end

  test "record_mailer_segment is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    event = mock_mailer_event(mailer: "UserMailer#welcome", to: ["a@b.com"], duration: 10.0)
    Catpm::SegmentSubscribers.send(:record_mailer_segment, event)

    assert_equal 0, @req_segments.segments.size
  end

  test "record_mailer_segment updates summary" do
    event = mock_mailer_event(mailer: "UserMailer#welcome", to: ["a@b.com"], duration: 50.0)
    Catpm::SegmentSubscribers.send(:record_mailer_segment, event)

    assert_equal 1, @req_segments.summary[:mailer_count]
    assert_in_delta 50.0, @req_segments.summary[:mailer_duration], 0.01
  end

  # ─── Storage segments (Tier 1) ───

  test "record_storage_segment adds upload segment" do
    event = mock_storage_event(key: "avatar.jpg", duration: 120.0)
    Catpm::SegmentSubscribers.send(:record_storage_segment, event, "upload")

    assert_equal 1, @req_segments.segments.size
    seg = @req_segments.segments.first
    assert_equal "storage", seg[:type]
    assert_equal 120.0, seg[:duration]
    assert_includes seg[:detail], "upload"
    assert_includes seg[:detail], "avatar.jpg"
  end

  test "record_storage_segment adds download segment" do
    event = mock_storage_event(key: "report.pdf", duration: 80.0)
    Catpm::SegmentSubscribers.send(:record_storage_segment, event, "download")

    assert_includes @req_segments.segments.first[:detail], "download"
    assert_includes @req_segments.segments.first[:detail], "report.pdf"
  end

  test "record_storage_segment is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    event = mock_storage_event(key: "file.txt", duration: 10.0)
    Catpm::SegmentSubscribers.send(:record_storage_segment, event, "upload")

    assert_equal 0, @req_segments.segments.size
  end

  test "record_storage_segment updates summary" do
    event = mock_storage_event(key: "file.txt", duration: 30.0)
    Catpm::SegmentSubscribers.send(:record_storage_segment, event, "upload")

    assert_equal 1, @req_segments.summary[:storage_count]
    assert_in_delta 30.0, @req_segments.summary[:storage_duration], 0.01
  end

  private

  def mock_sql_event(name:, sql:, duration:)
    OpenStruct.new(
      payload: { name: name, sql: sql },
      duration: duration
    )
  end

  def mock_view_event(identifier:, duration:)
    OpenStruct.new(
      payload: { identifier: identifier },
      duration: duration
    )
  end

  def mock_cache_event(key:, duration:, hit: nil)
    payload = { key: key }
    payload[:hit] = hit unless hit.nil?
    OpenStruct.new(
      payload: payload,
      duration: duration,
      time: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
  end

  def mock_mailer_event(mailer:, to:, duration:)
    OpenStruct.new(
      payload: { mailer: mailer, to: to },
      duration: duration,
      time: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
  end

  def mock_storage_event(key:, duration:)
    OpenStruct.new(
      payload: { key: key },
      duration: duration,
      time: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
  end
end
