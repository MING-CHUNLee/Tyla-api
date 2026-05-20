# frozen_string_literal: true

module Tyla
  module Values
    module AttackPolicy
      THRESHOLD = 0.7

      def self.allowed?(attack_probability)
        attack_probability < THRESHOLD
      end
    end
  end
end
