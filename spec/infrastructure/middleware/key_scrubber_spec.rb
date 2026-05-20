# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Middleware::KeyScrubber do
  def call_app(body_chunks)
    app = ->(_env) { [200, { 'Content-Type' => 'text/plain' }, body_chunks] }
    middleware = Tyla::Middleware::KeyScrubber.new(app)
    status, _headers, body = middleware.call({})
    [status, body.join]
  end

  it 'redacts an sk- key appearing bare in the body' do
    _status, body = call_app(['key was sk-abc123XYZ_more here'])
    _(body).wont_include 'sk-abc123XYZ_more'
    _(body).must_include '[REDACTED]'
  end

  it 'redacts the key part of an X-LLM-Key header dump' do
    _status, body = call_app(['X-LLM-Key: sk-secretvalue\nNext line'])
    _(body).wont_include 'sk-secretvalue'
    _(body).must_include '[REDACTED]'
  end

  it 'redacts the key part of a Bearer authorization header dump' do
    _status, body = call_app(['Authorization: Bearer sk-bearertoken_x'])
    _(body).wont_include 'sk-bearertoken_x'
    _(body).must_include '[REDACTED]'
  end

  it 'leaves a clean body unchanged' do
    _status, body = call_app(['{"status":"ok","content":"hello"}'])
    _(body).must_equal '{"status":"ok","content":"hello"}'
  end

  it 'passes through non-string chunks safely' do
    _status, body = call_app(['ok'])
    _(body).must_equal 'ok'
  end
end
