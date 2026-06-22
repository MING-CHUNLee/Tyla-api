# frozen_string_literal: true

module Tyla
  module Infrastructure
    # Generic, schema-agnostic extractor for provider rate-limit headers.
    # Providers disagree on names (OpenAI `x-ratelimit-remaining-requests`,
    # Anthropic `anthropic-ratelimit-requests-remaining`, GitHub Models TBD),
    # so we DO NOT hard-code a field set: we keep every header whose (downcased)
    # name contains "ratelimit", plus `retry-after`. "Provider gives what it
    # gives" — no assumptions about prefix, ordering, or reset-time units.
    module RateLimitHeaders
      module_function

      # response: a Net::HTTPResponse. Returns { downcased_name => value(String) }.
      def extract(response)
        headers = {}
        response.each_header do |name, value|
          key = name.to_s.downcase
          headers[key] = value if key.include?('ratelimit') || key == 'retry-after'
        end
        headers
      end
    end
  end
end
