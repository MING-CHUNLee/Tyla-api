# frozen_string_literal: true

module Tyla
  module Values
    # Derives a guard verdict from a persisted prompt_logs row. `prompt_logs`
    # has no status column, so the verdict is computed from the stored
    # `attack_probability`, mirroring how the guard itself decides
    # (Values::AttackPolicy). See plan §1.1.
    #
    #   nil       → :unavailable  (guard was fail-open / judge unavailable)
    #   < 0.7     → :done
    #   >= 0.7    → :forbidden
    module GuardLogVerdict
      # Returns :unavailable | :done | :forbidden from a persisted attack_probability.
      def self.from(attack_probability)
        return :unavailable if attack_probability.nil?

        Values::AttackPolicy.allowed?(attack_probability) ? :done : :forbidden
      end
    end
  end
end
