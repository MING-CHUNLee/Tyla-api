# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Infrastructure::RateLimitHeaders do
  # Minimal stand-in for a Net::HTTPResponse: only #each_header is exercised.
  def response_with(headers)
    resp = Object.new
    resp.define_singleton_method(:each_header) do |&block|
      headers.each { |name, value| block.call(name, value) }
    end
    resp
  end

  it 'keeps only headers whose name contains "ratelimit" plus retry-after' do
    resp = response_with(
      'content-type' => 'application/json',
      'x-ratelimit-remaining-requests' => '7',
      'retry-after' => '30',
      'x-request-id' => 'abc'
    )

    extracted = Tyla::Infrastructure::RateLimitHeaders.extract(resp)

    _(extracted).must_equal(
      'x-ratelimit-remaining-requests' => '7',
      'retry-after'                    => '30'
    )
  end

  it 'normalizes header names to lower-case' do
    resp = response_with(
      'X-RateLimit-Remaining-Requests' => '3',
      'Retry-After'                    => '12'
    )

    extracted = Tyla::Infrastructure::RateLimitHeaders.extract(resp)

    _(extracted['x-ratelimit-remaining-requests']).must_equal '3'
    _(extracted['retry-after']).must_equal '12'
  end

  it 'captures the Anthropic prefix too (not tied to the OpenAI x-ratelimit prefix)' do
    resp = response_with('anthropic-ratelimit-requests-remaining' => '4')

    extracted = Tyla::Infrastructure::RateLimitHeaders.extract(resp)

    _(extracted['anthropic-ratelimit-requests-remaining']).must_equal '4'
  end

  it 'returns {} when there are no rate-limit headers' do
    resp = response_with('content-type' => 'application/json', 'x-request-id' => 'abc')

    _(Tyla::Infrastructure::RateLimitHeaders.extract(resp)).must_equal({})
  end
end
