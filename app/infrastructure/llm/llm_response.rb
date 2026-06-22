# frozen_string_literal: true

module Tyla
  module Infrastructure
    # `rate_limit` carries the provider's pass-through rate-limit headers
    # (schema-agnostic bag; see RateLimitHeaders). Empty {} when none / unknown.
    LlmResponse = Data.define(:content, :usage, :tool_calls, :rate_limit) do
      def initialize(content:, usage:, tool_calls: [], rate_limit: {})
        super
      end
    end
  end
end
