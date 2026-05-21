# frozen_string_literal: true

module Tyla
  module Infrastructure
    class LlmClient
      def self.for(provider:, api_key:, model: nil, endpoint: nil)
        case provider
        when 'openai'    then OpenAiClient.new(api_key: api_key, model: model, endpoint: endpoint)
        when 'anthropic' then AnthropicClient.new(api_key: api_key, **({ model: model } if model).to_h)
        else raise LlmError::UnsupportedProvider, provider.to_s
        end
      end
    end
  end
end
