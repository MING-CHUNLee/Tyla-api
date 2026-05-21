# frozen_string_literal: true

require_relative '../../spec_helper'
require 'dry/monads'

Dir.glob(File.join(ROOT, 'app/application/services/rate_limiter.rb')).each { |f| require f }

module Tyla
  module Services
    describe RateLimiter do
      let(:limiter) { RateLimiter.new }
      let(:limit)   { Values::RateLimitPolicy::MAX_REQUESTS_PER_MINUTE }
      let(:student) { 'student-abc' }

      it 'returns Success when requests are under the limit' do
        result = limiter.check!(student)
        _(result).must_be :success?
      end

      it 'returns Failure[:rate_limited] when requests reach the limit' do
        limit.times { limiter.check!(student) }
        result = limiter.check!(student)
        _(result).must_be :failure?
        _(result.failure.first).must_equal :rate_limited
      end

      it 'does not rate-limit a different student_id' do
        limit.times { limiter.check!(student) }
        other = limiter.check!('other-student')
        _(other).must_be :success?
      end

      it 'resets the window after WINDOW_SECONDS have passed' do
        window = Values::RateLimitPolicy::WINDOW_SECONDS
        limit.times { limiter.check!(student) }
        # Simulate window expiry by back-dating the recorded timestamps
        past = Time.now.to_f - window - 1
        limiter.instance_variable_get(:@buckets)[student].map! { past }
        result = limiter.check!(student)
        _(result).must_be :success?
      end

      it 'is thread-safe under concurrent requests' do
        results = []
        mutex   = Mutex.new
        threads = (limit + 5).times.map do
          Thread.new do
            r = limiter.check!(student)
            mutex.synchronize { results << r }
          end
        end
        threads.each(&:join)
        successes = results.count(&:success?)
        failures  = results.count(&:failure?)
        _(successes).must_equal limit
        _(failures).must_equal 5
      end
    end
  end
end
