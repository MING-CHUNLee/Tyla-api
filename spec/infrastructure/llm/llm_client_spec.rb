# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Infrastructure::LlmClient do
  it 'returns an OpenAiClient for the openai provider' do
    client = Tyla::Infrastructure::LlmClient.for(provider: 'openai', api_key: 'sk-x')
    _(client).must_be_kind_of Tyla::Infrastructure::OpenAiClient
  end

  it 'returns an AnthropicClient for the anthropic provider' do
    client = Tyla::Infrastructure::LlmClient.for(provider: 'anthropic', api_key: 'sk-x')
    _(client).must_be_kind_of Tyla::Infrastructure::AnthropicClient
  end

  it 'raises LlmError::UnsupportedProvider for unknown providers' do
    _ { Tyla::Infrastructure::LlmClient.for(provider: 'gemini', api_key: 'sk-x') }
      .must_raise Tyla::Infrastructure::LlmError::UnsupportedProvider
  end
end
