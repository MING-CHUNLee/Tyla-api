# frozen_string_literal: true

require_relative '../../spec_helper'
require 'dry/monads'

%w[
  app/application/services/solution_loader.rb
  app/application/services/tutor_chat_result.rb
  app/application/services/tutor_chat_input.rb
  app/application/services/policy_loader.rb
  app/application/services/guard_agent.rb
  app/application/services/tutor_orchestrator.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Services
    describe TutorOrchestrator do
      include Dry::Monads[:result]

      # ── Helpers ──────────────────────────────────────────────────────────────

      def make_request(overrides = {})
        defaults = {
          course_id:     'CS101',
          project_id:    'proj-1',
          student_id:    'stu-1',
          mode:          'tutor-socratic',
          user_prompt:   'How does bubble sort work?',
          history:       [],
          context_files: []
        }
        TutorChatInput.new(**defaults.merge(overrides))
      end

      def stub_llm(content: 'tutor reply', usage: { input_tokens: 10, output_tokens: 5 })
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_|
          Infrastructure::LlmResponse.new(content: content, usage: usage)
        end
        client
      end

      def counting_llm(counter, content: 'reply')
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_|
          counter << :called
          Infrastructure::LlmResponse.new(content: content, usage: {})
        end
        client
      end

      def raising_llm(error_class, message = 'upstream error')
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_|
          raise error_class, message
        end
        client
      end

      def allowed_guard
        Values::GuardResult.new(reason: 'ok', probability: { attack: 0.1 })
      end

      def blocked_guard
        Values::GuardResult.new(reason: 'jailbreak', probability: { attack: 0.9 })
      end

      def stub_guard(result)
        g = Object.new
        g.define_singleton_method(:check) { |**_| result }
        g
      end

      let(:policy_loader) { PolicyLoader.new }

      # ── Tests ─────────────────────────────────────────────────────────────────

      it '(a) allowed path calls the tutor LLM and returns Success with ok result' do
        orch   = TutorOrchestrator.new(
          llm_client:    stub_llm(content: 'great explanation'),
          guard:         stub_guard(allowed_guard),
          policy_loader: policy_loader
        )
        outcome = orch.call(make_request)
        _(outcome).must_be :success?
        result = outcome.value!
        _(result.status).must_equal 'ok'
        _(result.content).must_equal 'great explanation'
      end

      it '(b) refused path returns Success with refused result and does NOT call the tutor LLM' do
        call_log = []
        orch = TutorOrchestrator.new(
          llm_client:    counting_llm(call_log),
          guard:         stub_guard(blocked_guard),
          policy_loader: policy_loader
        )
        outcome = orch.call(make_request)
        _(outcome).must_be :success?
        result = outcome.value!
        _(result.status).must_equal 'refused'
        _(result.content).wont_be_empty
        _(call_log).must_be_empty
      end

      it '(c) history is truncated to MAX_HISTORY_TURNS * 2 messages' do
        max = Values::PayloadLimits::MAX_HISTORY_TURNS
        long_history = (max * 2 + 4).times.map { |i| { role: i.even? ? 'user' : 'assistant', content: "msg #{i}" } }
        captured_args = nil
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          captured_args = kwargs
          Infrastructure::LlmResponse.new(content: 'reply', usage: {})
        end
        orch = TutorOrchestrator.new(
          llm_client:    client,
          guard:         stub_guard(allowed_guard),
          policy_loader: policy_loader
        )
        orch.call(make_request(history: long_history))
        _(captured_args[:history].size).must_equal max * 2
      end

      it '(d) file content is truncated at MAX_FILE_LINES' do
        max   = Values::PayloadLimits::MAX_FILE_LINES
        lines = (max + 10).times.map { |i| "line #{i}\n" }.join
        files = [{ path: 'hw.R', content: lines }]
        system_prompt_used = nil
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          system_prompt_used = kwargs[:system_prompt]
          Infrastructure::LlmResponse.new(content: 'reply', usage: {})
        end
        orch = TutorOrchestrator.new(
          llm_client:    client,
          guard:         stub_guard(allowed_guard),
          policy_loader: policy_loader
        )
        orch.call(make_request(context_files: files))
        _(system_prompt_used).must_include 'truncated'
      end

      it '(e) LLM timeout returns Failure[:upstream_timeout]' do
        orch = TutorOrchestrator.new(
          llm_client:    raising_llm(Infrastructure::LlmError::Timeout),
          guard:         stub_guard(allowed_guard),
          policy_loader: policy_loader
        )
        outcome = orch.call(make_request)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :upstream_timeout
      end

      it '(f) LLM upstream error returns Failure[:upstream_error]' do
        orch = TutorOrchestrator.new(
          llm_client:    raising_llm(Infrastructure::LlmError::Upstream, 'HTTP 503'),
          guard:         stub_guard(allowed_guard),
          policy_loader: policy_loader
        )
        outcome = orch.call(make_request)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :upstream_error
      end

      it '(g) unknown mode returns Failure[:bad_mode]' do
        orch = TutorOrchestrator.new(
          llm_client:    stub_llm,
          guard:         stub_guard(allowed_guard),
          policy_loader: policy_loader
        )
        outcome = orch.call(make_request(mode: 'invalid-mode'))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_mode
      end
    end
  end
end
