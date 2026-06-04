# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webmock/minitest'

describe Tyla::Infrastructure::AnthropicClient do
  before do
    WebMock.disable_net_connect!
    WebMock.reset!
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  let(:client) { Tyla::Infrastructure::AnthropicClient.new(api_key: 'sk-ant-test') }

  it 'sends the x-api-key header and parses content/usage on success' do
    stub = stub_request(:post, 'https://api.anthropic.com/v1/messages')
           .with(
             headers: {
               'x-api-key'         => 'sk-ant-test',
               'anthropic-version' => '2023-06-01',
               'Content-Type'      => 'application/json'
             }
           )
           .to_return(
             status: 200,
             body: {
               content: [{ type: 'text', text: 'hello back' }],
               usage:   { input_tokens: 7, output_tokens: 3 }
             }.to_json,
             headers: { 'Content-Type' => 'application/json' }
           )

    resp = client.send_prompt(system_prompt: 'sys', user_message: 'hi')

    _(resp.content).must_equal 'hello back'
    _(resp.usage[:input_tokens]).must_equal 7
    _(resp.usage[:output_tokens]).must_equal 3
    assert_requested(stub)
  end

  it 'raises LlmError::Upstream on non-2xx response' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return(status: 503, body: 'overloaded')

    err = _ { client.send_prompt(system_prompt: 's', user_message: 'u') }
          .must_raise Tyla::Infrastructure::LlmError::Upstream
    _(err.message).must_match(/503/)
  end

  it 'raises LlmError::Timeout when the connection times out' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages').to_timeout

    _ { client.send_prompt(system_prompt: 's', user_message: 'u') }
      .must_raise Tyla::Infrastructure::LlmError::Timeout
  end
end
