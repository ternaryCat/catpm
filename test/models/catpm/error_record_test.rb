# frozen_string_literal: true

require "test_helper"

module Catpm
  class ErrorRecordTest < ActiveSupport::TestCase
    setup do
      @error = ErrorRecord.create!(
        fingerprint: "a" * 64,
        kind: "http",
        error_class: "ActiveRecord::RecordNotFound",
        message: "Couldn't find User with id=999",
        occurrences_count: 5,
        first_occurred_at: 1.hour.ago,
        last_occurred_at: Time.current,
        contexts: [{ occurred_at: Time.current.iso8601, backtrace: ["app/models/user.rb:in 'find'"] }]
      )
    end

    teardown do
      ErrorRecord.delete_all
    end

    test "creates valid error record" do
      assert @error.persisted?
    end

    test "requires fingerprint, kind, error_class, timestamps" do
      record = ErrorRecord.new
      refute record.valid?
      assert_includes record.errors[:fingerprint], "can't be blank"
      assert_includes record.errors[:kind], "can't be blank"
      assert_includes record.errors[:error_class], "can't be blank"
    end

    test "fingerprint uniqueness" do
      duplicate = ErrorRecord.new(
        fingerprint: @error.fingerprint,
        kind: "http",
        error_class: "SomeError",
        first_occurred_at: Time.current,
        last_occurred_at: Time.current
      )
      refute duplicate.valid?
      assert_includes duplicate.errors[:fingerprint], "has already been taken"
    end

    test "resolved? and resolve!" do
      refute @error.resolved?

      @error.resolve!
      assert @error.resolved?
      assert_not_nil @error.resolved_at
    end

    test "unresolve!" do
      @error.resolve!
      assert @error.resolved?

      @error.unresolve!
      refute @error.resolved?
    end

    test "unresolved scope" do
      assert_equal 1, ErrorRecord.unresolved.count
      @error.resolve!
      assert_equal 0, ErrorRecord.unresolved.count
    end

    test "resolved scope" do
      assert_equal 0, ErrorRecord.resolved.count
      @error.resolve!
      assert_equal 1, ErrorRecord.resolved.count
    end

    test "by_kind scope" do
      assert_equal 1, ErrorRecord.by_kind("http").count
      assert_equal 0, ErrorRecord.by_kind("job").count
    end

    test "parsed_contexts returns array" do
      contexts = @error.parsed_contexts
      assert_kind_of Array, contexts
      assert_equal 1, contexts.size
    end

    test "parsed_contexts with nil" do
      @error.update!(contexts: nil)
      assert_equal [], @error.parsed_contexts
    end
  end
end
