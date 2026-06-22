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
    end
  end
end
