# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::AttackPolicy do
  it 'sets THRESHOLD to 0.7' do
    _(Tyla::Values::AttackPolicy::THRESHOLD).must_equal 0.7
  end

  it 'allows attack-probability strictly below threshold' do
    _(Tyla::Values::AttackPolicy.allowed?(0.69)).must_equal true
    _(Tyla::Values::AttackPolicy.allowed?(0.0)).must_equal true
  end

  it 'blocks attack-probability at or above threshold' do
    _(Tyla::Values::AttackPolicy.allowed?(0.7)).must_equal false
    _(Tyla::Values::AttackPolicy.allowed?(0.95)).must_equal false
  end
end
