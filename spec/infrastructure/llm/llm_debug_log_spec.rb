# frozen_string_literal: true

require_relative '../../spec_helper'
require 'tmpdir'

describe Tyla::Infrastructure::LlmDebugLog do
  let(:log_dir)  { Dir.mktmpdir }
  let(:log_path) { File.join(log_dir, 'llm_debug.log') }

  after do
    ENV.delete('LLM_DEBUG_LOG')
    FileUtils.remove_entry(log_dir) if File.directory?(log_dir)
  end

  def contents = File.exist?(log_path) ? File.read(log_path) : ''

  describe 'when disabled (LLM_DEBUG_LOG unset)' do
    before { ENV.delete('LLM_DEBUG_LOG') }

    it 'is not enabled and writes nothing' do
      _(Tyla::Infrastructure::LlmDebugLog.enabled?).must_equal false

      trace = Tyla::Infrastructure::LlmDebugLog.request(
        provider: 'anthropic', model: 'm', endpoint: 'http://x', body: '{}'
      )

      _(trace).must_be_nil
      _(File.exist?(log_path)).must_equal false
    end

    it 'treats "0"/"false"/"off" as disabled' do
      %w[0 false off].each do |flag|
        ENV['LLM_DEBUG_LOG'] = flag
        _(Tyla::Infrastructure::LlmDebugLog.enabled?).must_equal false
      end
    end
  end

  describe 'when enabled with an explicit path' do
    before { ENV['LLM_DEBUG_LOG'] = log_path }

    it 'records the request body, response status and a correlated round-trip id' do
      trace = Tyla::Infrastructure::LlmDebugLog.request(
        provider: 'anthropic', model: 'claude-sonnet-4-6',
        endpoint: 'https://api.anthropic.com/v1/messages',
        body: { system: 'sys', messages: [{ role: 'user', content: 'hi' }] }.to_json
      )
      Tyla::Infrastructure::LlmDebugLog.response(
        trace, status: '200', body: { content: [{ type: 'text', text: 'hello' }] }.to_json
      )

      out = contents
      _(out).must_match(/REQUEST  model=claude-sonnet-4-6/)
      _(out).must_match(/RESPONSE status=200/)
      _(out).must_match(/"content"/)         # response body pretty-printed
      _(out).must_match(/##{trace.id} /)     # same id on both halves
    end

    it 'redacts API keys that appear in logged content' do
      trace = Tyla::Infrastructure::LlmDebugLog.request(
        provider: 'openai', model: 'gpt', endpoint: 'http://x', body: '{"note":"sk-secret-abc123"}'
      )
      Tyla::Infrastructure::LlmDebugLog.response(trace, status: '200', body: '{}')

      _(contents).wont_match(/sk-secret-abc123/)
      _(contents).must_match(/\[REDACTED\]/)
    end

    it 'logs raw body when it is not valid JSON (e.g. an upstream error page)' do
      trace = Tyla::Infrastructure::LlmDebugLog.request(
        provider: 'openai', model: 'gpt', endpoint: 'http://x', body: '{}'
      )
      Tyla::Infrastructure::LlmDebugLog.response(trace, status: '503', body: 'overloaded')

      _(contents).must_match(/status=503/)
      _(contents).must_match(/overloaded/)
    end

    it 'records a NO RESPONSE line on failure' do
      trace = Tyla::Infrastructure::LlmDebugLog.request(
        provider: 'anthropic', model: 'm', endpoint: 'http://x', body: '{}'
      )
      Tyla::Infrastructure::LlmDebugLog.failure(trace, error: 'request timed out')

      _(contents).must_match(/NO RESPONSE/)
      _(contents).must_match(/request timed out/)
    end
  end

  describe 'when LLM_DEBUG_LOG is a truthy flag' do
    it 'resolves to the default path' do
      ENV['LLM_DEBUG_LOG'] = '1'
      _(Tyla::Infrastructure::LlmDebugLog.path).must_equal 'log/llm_debug.log'
    end
  end
end
