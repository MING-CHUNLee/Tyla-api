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

      def send_prompt(system_prompt:, user_message:, history: [], max_tokens: nil, tools: [])
        messages = Array(history).map do |m|
          { role: m[:role] || m['role'], content: m[:content] || m['content'] }
        end
        messages << { role: 'user', content: user_message }

        body = {
          model:      @model,
          max_tokens: max_tokens || DEFAULT_MAX_TOKENS,
          system:     system_prompt,
          messages:   messages
        }
        body[:tools] = tools if tools.any?

        response = post_json(body.to_json)
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
        raise LlmError::Upstream, "anthropic returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        data   = JSON.parse(response.body)
        blocks = Array(data['content'])

        prose      = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.compact.join
        tool_calls = blocks.select { |b| b['type'] == 'tool_use' }.map do |b|
          { 'type' => b['name'] }.merge(b['input'] || {})
        end

        usage = {
          input_tokens:  data.dig('usage', 'input_tokens'),
          output_tokens: data.dig('usage', 'output_tokens')
        }
        LlmResponse.new(content: prose, usage: usage, tool_calls: tool_calls)
      rescue JSON::ParserError => e
        raise LlmError::Upstream, "anthropic returned malformed JSON: #{e.message}"
      end
    end
  end
end
