# frozen_string_literal: true

module Tyla
  module Infrastructure
    module LlmError
      class Base < StandardError; end
      class Timeout < Base; end
      class Upstream < Base; end
      class UnsupportedProvider < Base; end

      # 429 from the provider. Distinct from Upstream so the API can answer
      # 429 (+ Retry-After) instead of a generic 502, and the frontend can
      # back off rather than hammer-retry.
      class RateLimited < Base
        attr_reader :retry_after, :rate_limit

        def initialize(message = nil, retry_after: nil, rate_limit: {})
          super(message)
          @retry_after = retry_after
          @rate_limit  = rate_limit
        end
      end

      # 413 from the provider (per-request token cap exceeded; e.g. GitHub Models
      # `tokens_limit_reached`). Distinct from Upstream so the API can answer 413
      # instead of a generic 502, and the frontend can stop hammer-retrying (a 413
      # re-sent with the same body is always a 413 again). max_input_tokens is the
      # provider's per-model cap parsed from "Max size: N tokens" (nil if absent).
      class InputTooLarge < Base
        attr_reader :max_input_tokens, :provider_message

        def initialize(message = nil, max_input_tokens: nil, provider_message: nil)
          super(message)
          @max_input_tokens = max_input_tokens
          @provider_message = provider_message
        end
      end
    end
  end
end
