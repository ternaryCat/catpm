# frozen_string_literal: true

require "test_helper"

class FingerprintTest < ActiveSupport::TestCase
  test "generates consistent fingerprint" do
    fp1 = Catpm::Fingerprint.generate(
      kind: "http",
      error_class: "RuntimeError",
      backtrace: ["app/models/user.rb:42:in `validate'", "app/controllers/users_controller.rb:10:in `create'"]
    )
    fp2 = Catpm::Fingerprint.generate(
      kind: "http",
      error_class: "RuntimeError",
      backtrace: ["app/models/user.rb:42:in `validate'", "app/controllers/users_controller.rb:10:in `create'"]
    )

    assert_equal fp1, fp2
    assert_equal 64, fp1.length # SHA256 hex
  end

  test "different error classes produce different fingerprints" do
    fp1 = Catpm::Fingerprint.generate(kind: "http", error_class: "RuntimeError", backtrace: ["app/foo.rb:1:in `bar'"])
    fp2 = Catpm::Fingerprint.generate(kind: "http", error_class: "TypeError", backtrace: ["app/foo.rb:1:in `bar'"])

    refute_equal fp1, fp2
  end

  test "different kinds produce different fingerprints" do
    fp1 = Catpm::Fingerprint.generate(kind: "http", error_class: "RuntimeError", backtrace: ["app/foo.rb:1:in `bar'"])
    fp2 = Catpm::Fingerprint.generate(kind: "job", error_class: "RuntimeError", backtrace: ["app/foo.rb:1:in `bar'"])

    refute_equal fp1, fp2
  end

  test "strips line numbers for stability across deploys" do
    fp1 = Catpm::Fingerprint.generate(
      kind: "http",
      error_class: "RuntimeError",
      backtrace: ["app/models/user.rb:42:in `validate'"]
    )
    fp2 = Catpm::Fingerprint.generate(
      kind: "http",
      error_class: "RuntimeError",
      backtrace: ["app/models/user.rb:99:in `validate'"] # Different line number
    )

    assert_equal fp1, fp2
  end

  test "filters out gem and stdlib frames" do
    backtrace = [
      "/Users/user/.gems/gems/activerecord-7.0/lib/active_record/relation.rb:300:in `find'",
      "app/models/user.rb:42:in `validate'",
      "/Users/user/.asdf/installs/ruby/3.3.0/lib/ruby/3.3.0/json/common.rb:200:in `parse'",
      "app/controllers/users_controller.rb:10:in `create'"
    ]

    normalized = Catpm::Fingerprint.normalize_backtrace(backtrace)
    assert_includes normalized, "app/models/user.rb"
    assert_includes normalized, "app/controllers/users_controller.rb"
    refute_includes normalized, "activerecord"
    refute_includes normalized, "ruby/3.3.0"
  end

  test "takes only first 5 app frames" do
    backtrace = 10.times.map { |i| "app/models/model_#{i}.rb:#{i}:in `method_#{i}'" }
    normalized = Catpm::Fingerprint.normalize_backtrace(backtrace)
    lines = normalized.split("\n")

    assert_equal 5, lines.size
  end

  test "handles nil backtrace" do
    fp = Catpm::Fingerprint.generate(kind: "http", error_class: "RuntimeError", backtrace: nil)
    assert_equal 64, fp.length
  end

  test "handles empty backtrace" do
    fp = Catpm::Fingerprint.generate(kind: "http", error_class: "RuntimeError", backtrace: [])
    assert_equal 64, fp.length
  end
end
