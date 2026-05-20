# frozen_string_literal: true

module Tyla
  module Values
    class GuardResult
      attr_reader :reason, :probability

      def initialize(allowed:, reason:, probability: nil)
        @allowed     = allowed
        @reason      = reason
        @probability = probability
      end

      def allowed?
        @allowed
      end
    end
  end
end
