# frozen_string_literal: true

require_relative '../../spec_helper'
require 'dry/monads'
require 'sequel'

# ── In-memory test database ────────────────────────────────────────────────────
RGC_DB = Sequel.sqlite

RGC_DB.create_table(:prompt_logs) do
  primary_key :id
  String   :course_id,          null: false
  String   :project_id,         null: false
  String   :student_id,         null: false
  Text     :prompt,             null: false
  Float    :attack_probability
  Text     :evaluation
  DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
end

Sequel::Model.db = RGC_DB

require File.join(ROOT, 'app/infrastructure/database/orm/prompt_log_orm.rb')
require File.join(ROOT, 'app/infrastructure/database/repositories/prompt_logs.rb')

%w[
  app/application/requests/guard_check.rb
  app/presentation/representers/guard_check_representer.rb
  app/application/services/guard/run_guard_check.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Services
    describe RunGuardCheck do
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

      # The guard calls the LLM once; `verdict` controls the judge reply.
      def scripted_llm(verdict:, guard_usage: { input_tokens: 50, output_tokens: 8 })
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_kwargs|
          Infrastructure::LlmResponse.new(content: verdict.to_json, usage: guard_usage)
        end
        client
      end

      def raising_llm(error_class = RuntimeError, message = 'connection refused')
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_kwargs|
          raise error_class, message
        end
        client
      end

      def call_with(llm_client:, request: nil, headers: nil)
        request ||= valid_request
        headers ||= valid_headers
        Infrastructure::LlmClient.stub(:for, llm_client) do
          RunGuardCheck.new.call(request, headers)
        end
      end

      before do
        Tyla::Database::PromptLogOrm.dataset = RGC_DB[:prompt_logs]
        RGC_DB[:prompt_logs].delete
      end

      it 'returns Failure[:forbidden] when X-LLM-Key is missing' do
        outcome = RunGuardCheck.new.call(valid_request, valid_headers.reject { |k, _| k == 'HTTP_X_LLM_KEY' })
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :forbidden
      end

      it 'returns Failure[:bad_request] when the body is invalid' do
        bad     = valid_request.reject { |k, _| k == :prompt }
        client  = scripted_llm(verdict: { 'attack-probability' => 0.1, 'evaluation' => 'ok' })
        outcome = call_with(request: bad, llm_client: client)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
      end

      it 'allow verdict: returns Success[:done] with usage present and refusal nil' do
        client  = scripted_llm(verdict: { 'attack-probability' => 0.1, 'evaluation' => 'fine' })
        outcome = call_with(llm_client: client)
        _(outcome).must_be :success?
        kind, dto = outcome.value!
        _(kind).must_equal :done
        _(dto.status).must_equal 'done'
        _(dto.refusal).must_be_nil
        _(dto.usage).must_equal(input_tokens: 50, output_tokens: 8)
      end

      it 'allow verdict: persists a prompt_logs row with probability + evaluation' do
        client = scripted_llm(verdict: { 'attack-probability' => 0.2, 'evaluation' => 'normal' })
        call_with(llm_client: client)
        row = RGC_DB[:prompt_logs].first
        _(row).wont_be_nil
        _(row[:attack_probability]).must_be_close_to 0.2
        _(row[:evaluation]).must_equal 'normal'
      end

      it 'block verdict (attack >= 0.7): returns Success[:forbidden] with refusal present' do
        client  = scripted_llm(verdict: { 'attack-probability' => 0.95, 'evaluation' => 'jailbreak' })
        outcome = call_with(llm_client: client)
        _(outcome).must_be :success?
        kind, dto = outcome.value!
        _(kind).must_equal :forbidden
        _(dto.status).must_equal 'forbidden'
        _(dto.refusal).wont_be_nil
        _(dto.usage).must_equal(input_tokens: 50, output_tokens: 8)
      end

      it 'judge unavailable: returns Success[:unavailable] with usage and refusal nil' do
        client  = raising_llm
        outcome = call_with(llm_client: client)
        _(outcome).must_be :success?
        kind, dto = outcome.value!
        _(kind).must_equal :unavailable
        _(dto.status).must_equal 'unavailable'
        _(dto.usage).must_be_nil
        _(dto.refusal).must_be_nil
      end

      it 'judge reply unparseable: still treated as unavailable with usage forced nil' do
        client  = scripted_llm(verdict: 'not-json-at-all')
        outcome = call_with(llm_client: client)
        kind, dto = outcome.value!
        _(kind).must_equal :unavailable
        _(dto.status).must_equal 'unavailable'
        _(dto.usage).must_be_nil
        _(dto.refusal).must_be_nil
      end

      it 'returns Failure[:db_error] when the log write raises Sequel::Error' do
        client = scripted_llm(verdict: { 'attack-probability' => 0.1, 'evaluation' => 'ok' })
        Repository::PromptLogs.stub(:create, ->(*) { raise Sequel::Error, 'boom' }) do
          outcome = Infrastructure::LlmClient.stub(:for, client) do
            RunGuardCheck.new.call(valid_request, valid_headers)
          end
          _(outcome).must_be :failure?
          _(outcome.failure.first).must_equal :db_error
        end
      end
    end
  end
end
