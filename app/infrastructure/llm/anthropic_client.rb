# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module Tyla
  module Infrastructure
    class AnthropicClient
      ENDPOINT      = URI('https://api.anthropic.com/v1/messages')
      READ_TIMEOUT  = 30
      OPEN_TIMEOUT  = 10
      DEFAULT_MODEL = 'claude-sonnet-4-6'
      API_VERSION   = '2023-06-01'
      DEFAULT_MAX_TOKENS = 4096

      def initialize(api_key:, model: DEFAULT_MODEL)
        @api_key = api_key
        @model   = model
      end

      def send_prompt(system_prompt:, user_message:, history: [], max_tokens: nil)
        messages = Array(history).map do |m|
          { role: m[:role] || m['role'], content: m[:content] || m['content'] }
        end
        messages << { role: 'user', content: user_message }

        body = {
          model:      @model,
          max_tokens: max_tokens || DEFAULT_MAX_TOKENS,
          system:     system_prompt,
          messages:   messages
        }.to_json

        response = post_json(body)
        parse(response)
      end

      private

      def post_json(body)
        http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
        http.use_ssl = true
        http.read_timeout = READ_TIMEOUT
        http.open_timeout = OPEN_TIMEOUT

        request = Net::HTTP::Post.new(ENDPOINT.request_uri)
        request['x-api-key']          = @api_key
        request['anthropic-version']  = API_VERSION
        request['Content-Type']       = 'application/json'
        request.body = body

        http.request(request)
      rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ETIMEDOUT
        raise LlmError::Timeout, 'anthropic request timed out'
      end

      def parse(response)
        unless response.is_a?(Net::HTTPSuccess)
          raise LlmError::Upstream, "anthropic returned #{response.code}"
        end

        data    = JSON.parse(response.body)
        content = Array(data['content']).map { |c| c['text'] }.compact.join
        usage   = {
          input_tokens:  data.dig('usage', 'input_tokens'),
          output_tokens: data.dig('usage', 'output_tokens')
        }
        LlmResponse.new(content: content, usage: usage)
      rescue JSON::ParserError => e
        raise LlmError::Upstream, "anthropic returned malformed JSON: #{e.message}"
      end
    end
  end
end
