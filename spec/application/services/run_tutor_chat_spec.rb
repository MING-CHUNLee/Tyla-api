# frozen_string_literal: true

require_relative '../../spec_helper'
require 'dry/monads'
require 'sequel'

# ── In-memory test database ────────────────────────────────────────────────────
RTC_DB = Sequel.sqlite

RTC_DB.create_table(:prompt_logs) do
  primary_key :id
  String   :course_id,          null: false
  String   :project_id,         null: false
  String   :student_id,         null: false
  Text     :prompt,             null: false
  Float    :attack_probability
  Text     :evaluation
  DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
end

Sequel::Model.db = RTC_DB

require File.join(ROOT, 'app/infrastructure/database/orm/prompt_log_orm.rb')
require File.join(ROOT, 'app/infrastructure/database/repositories/prompt_logs.rb')

%w[
  app/application/requests/tutor_chat.rb
  app/application/services/tutor_chat/assignment_loader.rb
  app/application/services/tutor_chat/solution_loader.rb
  app/application/services/tutor_chat/student_file_loader.rb
  app/application/services/tutor_chat/tutor_persona_loader.rb
  app/application/services/tutor_chat/run_tutor_chat.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Services
    describe RunTutorChat do
      include Dry::Monads[:result]

      let(:valid_headers) do
        {
          'HTTP_X_LLM_PROVIDER' => 'openai',
          'HTTP_X_LLM_KEY'      => 'sk-test-key-abc'
        }
      end

      let(:valid_request) do
        {
          course_id:  'CSDS',
          project_id: 'HW2',
          student_id: 'stu-abc',
          prompt:     'Why is FD least sensitive to outliers?'
        }
      end

      # First call (guard) returns a JSON judge verdict; subsequent calls
      # (tutor) return plain reply text. `verdict` controls the guard verdict.
      def scripted_llm(verdict:, tutor_content: 'tutor reply', tutor_usage: { input_tokens: 10, output_tokens: 5 })
        call_log = []
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          call_log << kwargs
          if call_log.size == 1
            Infrastructure::LlmResponse.new(content: verdict.to_json, usage: {})
          else
            Infrastructure::LlmResponse.new(content: tutor_content, usage: tutor_usage)
          end
        end
        client.define_singleton_method(:calls) { call_log }
        client
      end

      def raising_after_guard(error_class, message = 'boom')
        call_log = []
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          call_log << kwargs
          if call_log.size == 1
            Infrastructure::LlmResponse.new(
              content: { 'attack-probability' => 0.1, 'evaluation' => 'ok' }.to_json,
              usage:   {}
            )
          else
            raise error_class, message
          end
        end
        client.define_singleton_method(:calls) { call_log }
        client
      end

      def call_with(llm_client:, request: nil, headers: nil)
        request ||= valid_request
        headers ||= valid_headers
        Infrastructure::LlmClient.stub(:for, llm_client) do
          RunTutorChat.new.call(request, headers)
        end
      end

      before do
        Tyla::Database::PromptLogOrm.dataset = RTC_DB[:prompt_logs]
        RTC_DB[:prompt_logs].delete
      end

      it 'returns Failure[:unauthorized] when X-LLM-Key is missing' do
        outcome = RunTutorChat.new.call(valid_request, valid_headers.reject { |k, _| k == 'HTTP_X_LLM_KEY' })
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :unauthorized
      end

      it 'returns Failure[:bad_request] when the body is invalid' do
        bad = valid_request.reject { |k, _| k == :prompt }
        client = scripted_llm(verdict: { 'attack-probability' => 0.1, 'evaluation' => 'ok' })
        outcome = call_with(request: bad, llm_client: client)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
      end

      it 'allowed path: calls the tutor LLM and returns Success[:ok] with content + usage' do
        client  = scripted_llm(verdict: { 'attack-probability' => 0.1, 'evaluation' => 'fine' },
                               tutor_content: 'Step 1: ...')
        outcome = call_with(llm_client: client)
        _(outcome).must_be :success?
        kind, payload = outcome.value!
        _(kind).must_equal :ok
        _(payload[:allowed]).must_equal true
        _(payload[:content]).must_equal 'Step 1: ...'
        _(payload[:usage][:input_tokens]).must_equal 10
        _(client.calls.size).must_equal 2 # guard + tutor
      end

      it 'allowed path: persists a prompt_logs row with the guard probability + evaluation' do
        client = scripted_llm(verdict: { 'attack-probability' => 0.2, 'evaluation' => 'normal' })
        call_with(llm_client: client)
        row = RTC_DB[:prompt_logs].first
        _(row).wont_be_nil
        _(row[:attack_probability]).must_be_close_to 0.2
        _(row[:evaluation]).must_equal 'normal'
      end

      it 'blocked path: skips the tutor LLM and returns refusal payload' do
        client  = scripted_llm(verdict: { 'attack-probability' => 0.95, 'evaluation' => 'jailbreak' })
        outcome = call_with(llm_client: client)
        _(outcome).must_be :success?
        kind, payload = outcome.value!
        _(kind).must_equal :blocked
        _(payload[:allowed]).must_equal false
        _(payload[:attack_probability]).must_be_close_to 0.95
        _(payload[:evaluation]).must_equal 'jailbreak'
        _(payload[:refusal]).wont_be_empty
        _(client.calls.size).must_equal 1 # guard only
      end

      it 'fail-open path: when guard JSON is malformed the tutor LLM is still called and warning is attached' do
        client  = scripted_llm(verdict: 'not-json-at-all', tutor_content: 'fallback reply')
        outcome = call_with(llm_client: client)
        _(outcome).must_be :success?
        kind, payload = outcome.value!
        _(kind).must_equal :llm_unavailable
        _(payload[:allowed]).must_equal true
        _(payload[:content]).must_equal 'fallback reply'
        _(payload[:warning]).must_match(/llm unavailable/)
        _(client.calls.size).must_equal 2
      end

      it 'returns Failure[:upstream_timeout] when the tutor LLM times out' do
        client  = raising_after_guard(Infrastructure::LlmError::Timeout)
        outcome = call_with(llm_client: client)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :upstream_timeout
      end

      it 'returns Failure[:upstream_error] when the tutor LLM upstream fails' do
        client  = raising_after_guard(Infrastructure::LlmError::Upstream, 'HTTP 503')
        outcome = call_with(llm_client: client)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :upstream_error
      end

      it 'tutor system prompt embeds persona, assignment, solution and student file' do
        captured = nil
        client = Object.new
        call_log = []
        client.define_singleton_method(:send_prompt) do |**kwargs|
          call_log << kwargs
          if call_log.size == 1
            Infrastructure::LlmResponse.new(
              content: { 'attack-probability' => 0.05, 'evaluation' => 'ok' }.to_json, usage: {}
            )
          else
            captured = kwargs
            Infrastructure::LlmResponse.new(content: 'ok', usage: {})
          end
        end

        call_with(llm_client: client)

        _(captured).wont_be_nil
        prompt = captured[:system_prompt]
        _(prompt).must_include 'Tutor-Guide Mode'   # persona
        _(prompt).must_include '## Assignment'      # assignment header
        _(prompt).must_include '## Reference Solution'
        _(prompt).must_include 'Hw2.Rmd'            # student file
        _(captured[:user_message]).must_equal valid_request[:prompt]
      end
    end
  end
end
