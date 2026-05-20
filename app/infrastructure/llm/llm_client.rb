# frozen_string_literal: true

module Tyla
  module Infrastructure
    class LlmClient
      def self.for(provider:, api_key:)
        case provider
        when 'openai'    then OpenAiClient.new(api_key: api_key)
        when 'anthropic' then AnthropicClient.new(api_key: api_key)
        else raise LlmError::UnsupportedProvider, provider.to_s
        end
      end
    end
  end
end
