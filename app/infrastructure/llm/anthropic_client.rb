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
        trace    = LlmDebugLog.request(provider: 'anthropic', model: @model, endpoint: ENDPOINT.to_s, body: body)
        response = open_http.request(build_request(body))
        LlmDebugLog.response(trace, status: response.code, body: response.body, headers: response.to_hash)
        response
      rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ETIMEDOUT
        LlmDebugLog.failure(trace, error: 'request timed out')
        raise LlmError::Timeout, 'anthropic request timed out'
      end

      def open_http
        http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
        http.use_ssl = true
        http.read_timeout = READ_TIMEOUT
        http.open_timeout = OPEN_TIMEOUT
        http
      end

      def build_request(body)
        request = Net::HTTP::Post.new(ENDPOINT.request_uri)
        request['x-api-key']          = @api_key
        request['anthropic-version']  = API_VERSION
        request['Content-Type']       = 'application/json'
        request.body = body
        request
      end

      # 429 → distinct RateLimited (with the provider's Retry-After + header bag)
      # so the API can answer 429 and the frontend can back off; any other non-2xx
      # stays a generic Upstream. No-op on a 2xx response.
      def raise_if_rate_limited(response, rate_limit)
        return unless response.is_a?(Net::HTTPTooManyRequests)

        raise LlmError::RateLimited.new(
          'anthropic rate limited (429)',
          retry_after: response['retry-after'],
          rate_limit:  rate_limit
        )
      end

      def parse(response)
        rate_limit = RateLimitHeaders.extract(response)
        raise_if_rate_limited(response, rate_limit)
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
        LlmResponse.new(content: prose, usage: usage, tool_calls: tool_calls, rate_limit: rate_limit)
      rescue JSON::ParserError => e
        raise LlmError::Upstream, "anthropic returned malformed JSON: #{e.message}"
      end
    end
  end
end
