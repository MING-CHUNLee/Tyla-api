# frozen_string_literal: true

module Tyla
  module Values
    class GuardResult
      attr_reader :reason, :probability

      def initialize(allowed: nil, reason:, probability: nil)
        @allowed     = allowed
        @reason      = reason
        @probability = probability
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
