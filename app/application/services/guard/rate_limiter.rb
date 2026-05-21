# frozen_string_literal: true

require 'dry/monads'

module Tyla
  module Services
    class RateLimiter
      include Dry::Monads[:result]

      POLICY = Values::RateLimitPolicy

      def initialize
        @mutex   = Mutex.new
        @buckets = Hash.new { |h, k| h[k] = [] }
      end

      def check!(student_id)
        now = Time.now.to_f
        @mutex.synchronize do
          window_start = now - POLICY::WINDOW_SECONDS
          @buckets[student_id].reject! { |t| t < window_start }
          if @buckets[student_id].size >= POLICY::MAX_REQUESTS_PER_MINUTE
            return Failure[:rate_limited, 'too many requests — please wait a moment']
          end

          @buckets[student_id] << now
        end
        Success(true)
      end
    end
  end
end
