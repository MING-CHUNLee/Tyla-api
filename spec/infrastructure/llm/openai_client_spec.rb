# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webmock/minitest'

describe Tyla::Infrastructure::OpenAiClient do
  before do
    WebMock.disable_net_connect!
    WebMock.reset!
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  let(:client) { Tyla::Infrastructure::OpenAiClient.new(api_key: 'sk-test-key') }

  it 'sends the Bearer auth header and parses choices/usage on success' do
    stub = stub_request(:post, 'https://api.openai.com/v1/chat/completions')
           .with(
             headers: { 'Authorization' => 'Bearer sk-test-key', 'Content-Type' => 'application/json' }
           )
           .to_return(
             status: 200,
             body: {
               choices: [{ message: { role: 'assistant', content: 'hi student' } }],
               usage:   { prompt_tokens: 12, completion_tokens: 5 }
             }.to_json,
             headers: { 'Content-Type' => 'application/json' }
           )

    resp = client.send_prompt(system_prompt: 'sys', user_message: 'hello')

    _(resp.content).must_equal 'hi student'
    _(resp.usage[:input_tokens]).must_equal 12
    _(resp.usage[:output_tokens]).must_equal 5
    assert_requested(stub)
  end

  it 'raises LlmError::Upstream on non-2xx response' do
    stub_request(:post, 'https://api.openai.com/v1/chat/completions')
      .to_return(status: 500, body: 'boom')

    err = _ { client.send_prompt(system_prompt: 's', user_message: 'u') }
          .must_raise Tyla::Infrastructure::LlmError::Upstream
    _(err.message).must_match(/500/)
  end

  it 'raises LlmError::Timeout when the connection times out' do
    stub_request(:post, 'https://api.openai.com/v1/chat/completions').to_timeout

    _ { client.send_prompt(system_prompt: 's', user_message: 'u') }
      .must_raise Tyla::Infrastructure::LlmError::Timeout
  end
end
