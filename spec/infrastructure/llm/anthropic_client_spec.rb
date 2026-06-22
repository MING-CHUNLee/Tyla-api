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
    _(resp.tool_calls).must_equal []
    assert_requested(stub)
  end

  it 'includes tools in the request body when provided' do
    tools = [{ name: 'edit_file', description: 'edit', input_schema: { type: 'object', properties: {}, required: [] } }]
    stub = stub_request(:post, 'https://api.anthropic.com/v1/messages')
           .with { |req| JSON.parse(req.body).key?('tools') }
           .to_return(
             status: 200,
             body: {
               content: [{ type: 'text', text: 'ok' }],
               usage:   { input_tokens: 5, output_tokens: 2 }
             }.to_json,
             headers: { 'Content-Type' => 'application/json' }
           )

    client.send_prompt(system_prompt: 'sys', user_message: 'hi', tools: tools)
    assert_requested(stub)
  end

  it 'omits tools key from request body when tools is empty' do
    stub = stub_request(:post, 'https://api.anthropic.com/v1/messages')
           .with { |req| !JSON.parse(req.body).key?('tools') }
           .to_return(
             status: 200,
             body: {
               content: [{ type: 'text', text: 'ok' }],
               usage:   { input_tokens: 5, output_tokens: 2 }
             }.to_json,
             headers: { 'Content-Type' => 'application/json' }
           )

    client.send_prompt(system_prompt: 'sys', user_message: 'hi')
    assert_requested(stub)
  end

  it 'parses tool_use blocks into tool_calls and keeps text blocks as content' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return(
        status: 200,
        body: {
          content: [
            { type: 'text', text: 'Here is the fix.' },
            { type: 'tool_use', name: 'edit_file',
              input: { 'path' => 'hw2.R', 'patches' => [{ 'search' => 'old', 'replace' => 'new' }] } }
          ],
          usage: { input_tokens: 20, output_tokens: 15 }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    resp = client.send_prompt(system_prompt: 'sys', user_message: 'fix it')

    _(resp.content).must_equal 'Here is the fix.'
    _(resp.tool_calls.size).must_equal 1
    _(resp.tool_calls.first['type']).must_equal 'edit_file'
    _(resp.tool_calls.first['path']).must_equal 'hw2.R'
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

  # ── Rate-limit pass-through (plan 2026-06-18 route C1) ──────────────────────

  it 'raises LlmError::RateLimited on 429, carrying retry-after and the rate-limit bag' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return(
        status: 429,
        body: 'rate limited',
        headers: { 'retry-after' => '15', 'anthropic-ratelimit-requests-remaining' => '0' }
      )

    err = _ { client.send_prompt(system_prompt: 's', user_message: 'u') }
          .must_raise Tyla::Infrastructure::LlmError::RateLimited
    _(err.retry_after).must_equal '15'
    _(err.rate_limit['anthropic-ratelimit-requests-remaining']).must_equal '0'
  end

  it 'passes the Anthropic-prefixed rate-limit header through on success' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return(
        status: 200,
        body: {
          content: [{ type: 'text', text: 'ok' }],
          usage:   { input_tokens: 5, output_tokens: 2 }
        }.to_json,
        headers: { 'Content-Type' => 'application/json', 'anthropic-ratelimit-requests-remaining' => '9' }
      )

    resp = client.send_prompt(system_prompt: 'sys', user_message: 'hi')

    _(resp.rate_limit['anthropic-ratelimit-requests-remaining']).must_equal '9'
  end
end
