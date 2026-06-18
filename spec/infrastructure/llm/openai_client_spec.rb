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
    _(resp.tool_calls).must_equal []
    assert_requested(stub)
  end

  it 'includes tools in OpenAI function-calling format when provided' do
    tools = [
      {
        name: 'edit_file',
        description: 'edit a file',
        input_schema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] }
      }
    ]
    stub = stub_request(:post, 'https://api.openai.com/v1/chat/completions')
           .with do |req|
             body = JSON.parse(req.body)
             body['tools']&.first&.dig('type') == 'function' &&
               body['tools'].first.dig('function', 'name') == 'edit_file' &&
               body['tools'].first.dig('function', 'parameters', 'type') == 'object'
           end
           .to_return(
             status: 200,
             body: {
               choices: [{ message: { role: 'assistant', content: 'ok' } }],
               usage:   { prompt_tokens: 5, completion_tokens: 2 }
             }.to_json,
             headers: { 'Content-Type' => 'application/json' }
           )

    client.send_prompt(system_prompt: 'sys', user_message: 'hi', tools: tools)
    assert_requested(stub)
  end

  it 'parses tool_calls from the OpenAI response and maps them to the shared format' do
    stub_request(:post, 'https://api.openai.com/v1/chat/completions')
      .to_return(
        status: 200,
        body: {
          choices: [
            {
              message: {
                role: 'assistant',
                content: nil,
                tool_calls: [
                  {
                    id: 'call_abc',
                    type: 'function',
                    function: {
                      name: 'edit_file',
                      arguments: '{"path":"hw2.R","patches":[{"search":"old","replace":"new"}]}'
                    }
                  }
                ]
              }
            }
          ],
          usage: { prompt_tokens: 20, completion_tokens: 10 }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    resp = client.send_prompt(system_prompt: 'sys', user_message: 'fix it')

    _(resp.tool_calls.size).must_equal 1
    _(resp.tool_calls.first['type']).must_equal 'edit_file'
    _(resp.tool_calls.first['path']).must_equal 'hw2.R'
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

  # ── Rate-limit pass-through (plan 2026-06-18 route C1) ──────────────────────

  it 'raises LlmError::RateLimited on 429, carrying retry-after and the rate-limit bag' do
    stub_request(:post, 'https://api.openai.com/v1/chat/completions')
      .to_return(
        status: 429,
        body: 'rate limited',
        headers: { 'Retry-After' => '30', 'x-ratelimit-remaining-requests' => '0' }
      )

    err = _ { client.send_prompt(system_prompt: 's', user_message: 'u') }
          .must_raise Tyla::Infrastructure::LlmError::RateLimited
    _(err.retry_after).must_equal '30'
    _(err.rate_limit['x-ratelimit-remaining-requests']).must_equal '0'
    _(err.rate_limit['retry-after']).must_equal '30'
  end

  it 'passes rate-limit headers through on a successful response' do
    stub_request(:post, 'https://api.openai.com/v1/chat/completions')
      .to_return(
        status: 200,
        body: {
          choices: [{ message: { role: 'assistant', content: 'ok' } }],
          usage:   { prompt_tokens: 5, completion_tokens: 2 }
        }.to_json,
        headers: { 'Content-Type' => 'application/json', 'x-ratelimit-remaining-requests' => '5' }
      )

    resp = client.send_prompt(system_prompt: 'sys', user_message: 'hi')

    _(resp.rate_limit['x-ratelimit-remaining-requests']).must_equal '5'
  end

  it 'defaults rate_limit to {} when the response carries no rate-limit headers' do
    stub_request(:post, 'https://api.openai.com/v1/chat/completions')
      .to_return(
        status: 200,
        body: {
          choices: [{ message: { role: 'assistant', content: 'ok' } }],
          usage:   { prompt_tokens: 5, completion_tokens: 2 }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    resp = client.send_prompt(system_prompt: 'sys', user_message: 'hi')

    _(resp.rate_limit).must_equal({})
  end
end
