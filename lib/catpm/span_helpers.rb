# frozen_string_literal: true

module Catpm
  # Declarative method tracing, similar to Elastic APM's SpanHelpers.
  #
  #   class PaymentService
  #     include Catpm::SpanHelpers
  #
  #     def process(order)
  #       # ...
  #     end
  #     span_method :process
  #
  #     def self.bulk_charge(users)
  #       # ...
  #     end
  #     span_class_method :bulk_charge
  #   end
  #
  module SpanHelpers
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def span_method(method_name, span_name = nil)
        method_name = method_name.to_sym
        span_name ||= "#{name}##{method_name}"

        mod = Module.new do
          define_method(method_name) do |*args, **kwargs, &block|
            Catpm.span(span_name) { super(*args, **kwargs, &block) }
          end
        end
        prepend(mod)
      end

      def span_class_method(method_name, span_name = nil)
        method_name = method_name.to_sym
        span_name ||= "#{name}.#{method_name}"

        mod = Module.new do
          define_method(method_name) do |*args, **kwargs, &block|
            Catpm.span(span_name) { super(*args, **kwargs, &block) }
          end
        end
        singleton_class.prepend(mod)
      end
    end
  end
end
