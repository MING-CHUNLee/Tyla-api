# frozen_string_literal: true

module Tyla
  module Values
    class GuardResult
      attr_reader :reason, :probability, :usage

      def initialize(allowed: nil, reason:, probability: nil, usage: nil)
        @allowed     = allowed
        @reason      = reason
        @probability = probability
        @usage       = usage
      end

      def allowed?
        if @probability
          Values::AttackPolicy.allowed?(@probability[:attack])
        else
          @allowed
        end
      end
    end
  end
end
