# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module Tyla
  module Infrastructure
    class OpenAiClient
      DEFAULT_ENDPOINT = 'https://api.openai.com/v1/chat/completions'
      READ_TIMEOUT     = 30
      OPEN_TIMEOUT     = 10
      DEFAULT_MODEL    = 'gpt-4o-mini'

      def initialize(api_key:, model: nil, endpoint: nil)
        @api_key  = api_key
        @model    = model || ENV.fetch('LLM_MODEL', DEFAULT_MODEL)
        @endpoint = URI(endpoint || ENV.fetch('OPENAI_API_BASE', DEFAULT_ENDPOINT))
      end

      def send_prompt(system_prompt:, user_message:, history: [], max_tokens: nil, tools: [])
        messages = [{ role: 'system', content: system_prompt }]
        Array(history).each do |m|
          messages << { role: m[:role] || m['role'], content: m[:content] || m['content'] }
        end
        messages << { role: 'user', content: user_message }

        payload = { model: @model, messages: messages }
        payload[:max_tokens] = max_tokens unless max_tokens.nil?
        payload[:tools]      = openai_tools(tools) if tools.any?

        response = post_json(payload.to_json)
        parse(response)
      end

      private

      # Convert from the shared Anthropic-schema format (input_schema:) to the
      # OpenAI function-calling wrapper (type: "function", function: { parameters: }).
      def openai_tools(tools)
        tools.map do |t|
          {
            type: 'function',
            function: {
              name:        t[:name]        || t['name'],
              description: t[:description] || t['description'],
              parameters:  t[:input_schema] || t['input_schema']
            }
          }
        end
      end

      def post_json(body)
        warn "[OpenAiClient] POST #{@endpoint} (key: #{@api_key[0..6]}...)"
        http = Net::HTTP.new(@endpoint.host, @endpoint.port)
        http.use_ssl = @endpoint.scheme == 'https'
        http.read_timeout = READ_TIMEOUT
        http.open_timeout = OPEN_TIMEOUT

        request = Net::HTTP::Post.new(@endpoint.request_uri)
        request['Authorization'] = "Bearer #{@api_key}"
        request['Content-Type']  = 'application/json'
        request.body = body

        http.request(request)
      rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ETIMEDOUT
        raise LlmError::Timeout, 'openai request timed out'
      end

      def parse(response)
        raise LlmError::Upstream, "openai returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        data    = JSON.parse(response.body)
        message = data.dig('choices', 0, 'message') || {}
        content = message['content'].to_s
        usage   = {
          input_tokens:  data.dig('usage', 'prompt_tokens'),
          output_tokens: data.dig('usage', 'completion_tokens')
        }

        tool_calls = Array(message['tool_calls']).map do |tc|
          name = tc.dig('function', 'name')
          args = JSON.parse(tc.dig('function', 'arguments') || '{}')
          { 'type' => name }.merge(args)
        rescue JSON::ParserError
          nil
        end.compact

        LlmResponse.new(content: content, usage: usage, tool_calls: tool_calls)
      rescue JSON::ParserError => e
        raise LlmError::Upstream, "openai returned malformed JSON: #{e.message}"
      end
    end
  end
end
