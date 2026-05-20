# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module Tyla
  module Infrastructure
    class OpenAiClient
      ENDPOINT      = URI('https://api.openai.com/v1/chat/completions')
      READ_TIMEOUT  = 30
      OPEN_TIMEOUT  = 10
      DEFAULT_MODEL = 'gpt-4o-mini'

      def initialize(api_key:, model: DEFAULT_MODEL)
        @api_key = api_key
        @model   = model
      end

      def send_prompt(system_prompt:, user_message:, history: [])
        messages = [{ role: 'system', content: system_prompt }]
        Array(history).each do |m|
          messages << { role: m[:role] || m['role'], content: m[:content] || m['content'] }
        end
        messages << { role: 'user', content: user_message }

        body = { model: @model, messages: messages }.to_json
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
        request['Authorization'] = "Bearer #{@api_key}"
        request['Content-Type']  = 'application/json'
        request.body = body

        http.request(request)
      rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ETIMEDOUT
        raise LlmError::Timeout, 'openai request timed out'
      end

      def parse(response)
        unless response.is_a?(Net::HTTPSuccess)
          raise LlmError::Upstream, "openai returned #{response.code}"
        end

        data    = JSON.parse(response.body)
        content = data.dig('choices', 0, 'message', 'content').to_s
        usage   = {
          input_tokens:  data.dig('usage', 'prompt_tokens'),
          output_tokens: data.dig('usage', 'completion_tokens')
        }
        LlmResponse.new(content: content, usage: usage)
      rescue JSON::ParserError => e
        raise LlmError::Upstream, "openai returned malformed JSON: #{e.message}"
      end
    end
  end
end
