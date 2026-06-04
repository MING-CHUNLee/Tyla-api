# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::GuardLogVerdict do
  describe '.from' do
    it 'returns :unavailable when attack_probability is nil (fail-open)' do
      _(Tyla::Values::GuardLogVerdict.from(nil)).must_equal :unavailable
    end

    it 'returns :done when attack_probability is below the threshold' do
      _(Tyla::Values::GuardLogVerdict.from(0.0)).must_equal :done
      _(Tyla::Values::GuardLogVerdict.from(0.69)).must_equal :done
    end

    it 'returns :forbidden when attack_probability is at or above the threshold' do
      _(Tyla::Values::GuardLogVerdict.from(0.7)).must_equal :forbidden
      _(Tyla::Values::GuardLogVerdict.from(0.95)).must_equal :forbidden
    end
  end
end
