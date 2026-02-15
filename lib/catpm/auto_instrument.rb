# frozen_string_literal: true

module Catpm
  # Zero-config service auto-instrumentation.
  #
  # Detects common service base classes (ApplicationService, BaseService)
  # and prepends span tracking on their .call class method. Since subclasses
  # inherit .call from the base, ALL service objects get instrumented
  # automatically — no code changes, no configuration lists.
  #
  # The typical Rails service pattern:
  #   class ApplicationService
  #     def self.call(...) = new(...).call
  #   end
  #
  #   class Sync::Processor < ApplicationService
  #     def call = ...
  #   end
  #
  # After auto-instrumentation, Sync::Processor.call creates a span
  # named "Sync::Processor#call" that wraps the entire service execution.
  #
  # Custom base classes:
  #   Catpm.configure { |c| c.service_base_classes = ["MyBase"] }
  #
  # Explicit method list for edge cases:
  #   Catpm.configure do |c|
  #     c.auto_instrument_methods = ["Worker#process", "Gateway.charge"]
  #   end
  #
  module AutoInstrument
    DEFAULT_SERVICE_BASES = %w[
      ApplicationService
      BaseService
    ].freeze

    class << self
      def apply!
        instrument_service_bases
        instrument_explicit_methods
      end

      def reset!
        @applied = Set.new
        @bases_applied = Set.new
      end

      private

      # ─── Auto-detect service base classes ───

      def instrument_service_bases
        @bases_applied ||= Set.new

        bases = Catpm.config.service_base_classes
        bases = DEFAULT_SERVICE_BASES if bases.nil?

        bases.each do |base_name|
          next if @bases_applied.include?(base_name)

          begin
            klass = Object.const_get(base_name)
          rescue NameError
            next
          end

          next unless klass.is_a?(Class)

          # Prepend on the class-level .call so ALL subclasses get instrumented.
          # Since subclasses inherit .call from the base and only override
          # instance #call, this single prepend covers everything.
          if klass.respond_to?(:call)
            # Guard against double-prepend (e.g. code reloading in development)
            already = klass.singleton_class.ancestors.any? do |a|
              a.instance_variable_defined?(:@catpm_service_span)
            end
            next if already

            mod = Module.new do
              @catpm_service_span = true

              define_method(:call) do |*args, **kwargs, &block|
                Catpm.span("#{name}#call", type: :code) { super(*args, **kwargs, &block) }
              end
            end
            klass.singleton_class.prepend(mod)
          end

          @bases_applied << base_name
        end
      end

      # ─── Explicit method list ───

      def instrument_explicit_methods
        methods = Catpm.config.auto_instrument_methods
        return if methods.nil? || methods.empty?

        @applied ||= Set.new

        methods.each do |method_spec|
          next if @applied.include?(method_spec)

          if method_spec.include?('#')
            class_name, method_name = method_spec.split('#', 2)
            instrument_instance_method(class_name, method_name, method_spec)
          elsif method_spec.include?('.')
            class_name, method_name = method_spec.split('.', 2)
            instrument_class_method(class_name, method_name, method_spec)
          end
        end
      end

      def instrument_instance_method(class_name, method_name, spec)
        klass = Object.const_get(class_name)
        span_name = spec

        mod = Module.new do
          define_method(method_name.to_sym) do |*args, **kwargs, &block|
            Catpm.span(span_name) { super(*args, **kwargs, &block) }
          end
        end
        klass.prepend(mod)
        @applied << spec
      rescue NameError
        nil
      end

      def instrument_class_method(class_name, method_name, spec)
        klass = Object.const_get(class_name)
        span_name = spec

        mod = Module.new do
          define_method(method_name.to_sym) do |*args, **kwargs, &block|
            Catpm.span(span_name) { super(*args, **kwargs, &block) }
          end
        end
        klass.singleton_class.prepend(mod)
        @applied << spec
      rescue NameError
        nil
      end
    end
  end
end
