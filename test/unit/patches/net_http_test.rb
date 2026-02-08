# frozen_string_literal: true

require "test_helper"
require "net/http"
require "catpm/patches/net_http"

class NetHttpPatchTest < ActiveSupport::TestCase
  setup do
    Catpm.reset_config!
    Catpm.configure { |c| c.enabled = true; c.segment_source_threshold = 100.0 }
    @req_segments = Catpm::RequestSegments.new(max_segments: 50)
  end

  teardown do
    Thread.current[:catpm_request_segments] = nil
  end

  test "patch module is defined" do
    assert defined?(Catpm::Patches::NetHttp)
    assert Catpm::Patches::NetHttp.instance_method(:request)
  end

  test "patch is no-op without request context" do
    Thread.current[:catpm_request_segments] = nil

    mock_http = Object.new
    mock_http.instance_variable_set(:@address, "example.com")
    mock_http.define_singleton_method(:request) do |req, body = nil, &block|
      Net::HTTPResponse.new("1.1", "200", "OK")
    end
    mock_http.singleton_class.prepend(Catpm::Patches::NetHttp)

    mock_http.request(Net::HTTP::Get.new("/"))

    # No segments recorded because no request context
    assert_equal 0, @req_segments.segments.size
  end

  test "patch records http segment when request context present" do
    Thread.current[:catpm_request_segments] = @req_segments

    # Use a mock-like approach: create a Net::HTTP subclass with prepend
    # and test the segment recording logic directly
    mock_http = Object.new
    mock_http.instance_variable_set(:@address, "api.example.com")
    mock_http.define_singleton_method(:request) do |req, body = nil, &block|
      # Simulate super returning a response
      response = Net::HTTPResponse.new("1.1", "200", "OK")
      response
    end

    # Prepend the patch
    mock_http.singleton_class.prepend(Catpm::Patches::NetHttp)

    req = Net::HTTP::Get.new("/v1/users")
    mock_http.request(req)

    assert_equal 1, @req_segments.segments.size
    seg = @req_segments.segments.first
    assert_equal "http", seg[:type]
    assert_includes seg[:detail], "GET"
    assert_includes seg[:detail], "api.example.com"
    assert_includes seg[:detail], "/v1/users"
    assert_includes seg[:detail], "200"
    assert seg[:duration] >= 0
  end

  test "patch records duration accurately" do
    Thread.current[:catpm_request_segments] = @req_segments

    mock_http = Object.new
    mock_http.instance_variable_set(:@address, "slow.api.com")
    mock_http.define_singleton_method(:request) do |req, body = nil, &block|
      sleep(0.05) # 50ms
      Net::HTTPResponse.new("1.1", "201", "Created")
    end
    mock_http.singleton_class.prepend(Catpm::Patches::NetHttp)

    req = Net::HTTP::Post.new("/data")
    mock_http.request(req)

    seg = @req_segments.segments.first
    assert_includes seg[:detail], "POST"
    assert_includes seg[:detail], "201"
    assert seg[:duration] >= 40.0 # at least 40ms (allowing for timing variance)
  end

  test "patch updates http summary counters" do
    Thread.current[:catpm_request_segments] = @req_segments

    mock_http = Object.new
    mock_http.instance_variable_set(:@address, "api.com")
    mock_http.define_singleton_method(:request) do |req, body = nil, &block|
      Net::HTTPResponse.new("1.1", "200", "OK")
    end
    mock_http.singleton_class.prepend(Catpm::Patches::NetHttp)

    mock_http.request(Net::HTTP::Get.new("/a"))
    mock_http.request(Net::HTTP::Get.new("/b"))

    assert_equal 2, @req_segments.summary[:http_count]
    assert @req_segments.summary[:http_duration] > 0
  end
end
