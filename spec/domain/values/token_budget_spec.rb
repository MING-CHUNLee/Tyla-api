# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::TokenBudget do
  describe '.for' do
    it 'maps GitHub Models (Azure host) to :github_models_free with 8 K / 4 K' do
      budget = Tyla::Values::TokenBudget.for(
        endpoint: 'https://models.inference.ai.azure.com/chat/completions'
      )
      _(budget.channel).must_equal :github_models_free
      _(budget.input_token_limit).must_equal 8_000
      _(budget.output_reservation).must_equal 4_000
    end

    it 'maps models.github.ai to :github_models_free' do
      budget = Tyla::Values::TokenBudget.for(endpoint: 'https://models.github.ai/anything')
      _(budget.channel).must_equal :github_models_free
    end

    it 'maps api.openai.com to :openai_direct with 128 K / 4096' do
      budget = Tyla::Values::TokenBudget.for(endpoint: 'https://api.openai.com/v1/chat/completions')
      _(budget.channel).must_equal :openai_direct
      _(budget.input_token_limit).must_equal 128_000
      _(budget.output_reservation).must_equal 4_096
    end

    it 'maps api.anthropic.com to :anthropic_direct with 200 K / 4096' do
      budget = Tyla::Values::TokenBudget.for(endpoint: 'https://api.anthropic.com/v1/messages')
      _(budget.channel).must_equal :anthropic_direct
      _(budget.input_token_limit).must_equal 200_000
      _(budget.output_reservation).must_equal 4_096
    end

    it 'falls back to :unknown (8 K / 4 K) for unrecognised hosts' do
      budget = Tyla::Values::TokenBudget.for(endpoint: 'https://example.invalid/api')
      _(budget.channel).must_equal :unknown
      _(budget.input_token_limit).must_equal 8_000
      _(budget.output_reservation).must_equal 4_000
    end

    it 'falls back to :unknown for nil endpoint' do
      _(Tyla::Values::TokenBudget.for(endpoint: nil).channel).must_equal :unknown
    end

    it 'falls back to :unknown for empty endpoint' do
      _(Tyla::Values::TokenBudget.for(endpoint: '').channel).must_equal :unknown
    end

    it 'does not match host-suffix attacks (anchored host comparison, not substring)' do
      budget = Tyla::Values::TokenBudget.for(
        endpoint: 'https://evil.example.com.api.openai.com.attacker.test/'
      )
      _(budget.channel).must_equal :unknown
    end

    it 'compares host case-insensitively' do
      budget = Tyla::Values::TokenBudget.for(endpoint: 'https://API.OpenAI.com/v1/chat/completions')
      _(budget.channel).must_equal :openai_direct
    end

    it 'handles malformed endpoints by falling back to :unknown' do
      budget = Tyla::Values::TokenBudget.for(endpoint: 'not a url at all')
      _(budget.channel).must_equal :unknown
    end
  end
end
