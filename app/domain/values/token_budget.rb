# frozen_string_literal: true

require 'uri'

module Tyla
  module Values
    # Per-channel input/output token caps. Channel is derived from the LLM
    # endpoint host: students on GitHub Models (8 K input cap) vs. native
    # OpenAI/Anthropic keys (128 K / 200 K) have *very* different effective
    # budgets even for the same model. Match order matters — GitHub Models
    # first, then provider-direct hosts, then `:unknown` fallback (also 8 K,
    # because false-narrow is recoverable while false-wide is a hard 400).
    module TokenBudget
      CHANNELS = {
        github_models_free: {
          input:  8_000,
          output: 4_000,
          hosts:  %w[models.inference.ai.azure.com models.github.ai]
        },
        openai_direct: {
          input:  128_000,
          output: 4_096,
          hosts:  %w[api.openai.com]
        },
        anthropic_direct: {
          input:  200_000,
          output: 4_096,
          hosts:  %w[api.anthropic.com]
        },
        unknown: {
          input:  8_000,
          output: 4_000,
          hosts:  []
        }
      }.freeze

      MATCH_ORDER = %i[github_models_free openai_direct anthropic_direct].freeze

      Result = Struct.new(:channel, :input_token_limit, :output_reservation, keyword_init: true)

      def self.for(endpoint:)
        channel = detect_channel(endpoint)
        spec    = CHANNELS.fetch(channel)
        Result.new(
          channel:            channel,
          input_token_limit:  spec[:input],
          output_reservation: spec[:output]
        )
      end

      def self.detect_channel(endpoint)
        host = parse_host(endpoint)
        return :unknown if host.nil?

        MATCH_ORDER.each do |name|
          return name if CHANNELS.fetch(name)[:hosts].include?(host)
        end
        :unknown
      end

      def self.parse_host(endpoint)
        return nil if endpoint.nil? || endpoint.empty?

        uri = URI.parse(endpoint)
        host = uri.host
        host&.empty? ? nil : host&.downcase
      rescue URI::InvalidURIError
        nil
      end
      private_class_method :detect_channel, :parse_host
    end
  end
end
