# frozen_string_literal: true

require_relative '../../spec_helper'
require 'dry/monads'
require 'sequel'

# ── In-memory test database ────────────────────────────────────────────────────
HTCS_DB = Sequel.sqlite

HTCS_DB.create_table(:prompt_logs) do
  primary_key :id
  String   :course_id,          null: false
  String   :project_id,         null: false
  String   :student_id,         null: false
  Text     :prompt,             null: false
  Float    :attack_probability                       # nullable — pending row strategy
  Text     :evaluation                               # nullable — pending row strategy
  DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
end

Sequel::Model.db = HTCS_DB

# Load ORM, Repository, and all application services
require File.join(ROOT, 'app/infrastructure/database/orm/prompt_log_orm.rb')
require File.join(ROOT, 'app/infrastructure/database/repositories/prompt_logs.rb')

%w[
  app/application/services/tutor_chat/solution_loader.rb
  app/application/services/tutor_chat/tutor_chat_result.rb
  app/application/services/tutor_chat/tutor_chat_input.rb
  app/application/services/guard/rate_limiter.rb
  app/application/services/tutor_chat/policy_loader.rb
  app/application/services/guard/guard_agent.rb
  app/application/services/tutor_chat/tutor_orchestrator.rb
  app/application/services/tutor_chat/handle_tutor_chat.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Services
    describe HandleTutorChat do
      include Dry::Monads[:result]

      # ── Fixture helpers ──────────────────────────────────────────────────────

      VALID_HEADERS = {
        'X-LLM-Provider' => 'openai',
        'X-LLM-Key'      => 'sk-test-key-abc'
      }.freeze

      VALID_REQUEST = {
        course_id:   'CS101',
        project_id:  'proj-1',
        student_id:  'stu-xyz',
        mode:        'tutor-socratic',
        userPrompt:  'Explain bubble sort'
      }.freeze

      def stub_ok_llm
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_|
          Infrastructure::LlmResponse.new(content: 'great answer', usage: { input_tokens: 10, output_tokens: 5 })
        end
        client
      end

      def stub_refused_guard_llm
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          # Return a guard JSON only (all calls go through guard)
          Infrastructure::LlmResponse.new(
            content: { 'attack-probability' => 0.9, 'evaluation' => 'jailbreak' }.to_json,
            usage:   {}
          )
        end
        client
      end

      def fresh_rate_limiter
        RateLimiter.new
      end

      def call_with(request: VALID_REQUEST, headers: VALID_HEADERS, rate_limiter: fresh_rate_limiter, llm_client: nil)
        handler = HandleTutorChat.new(rate_limiter: rate_limiter)
        if llm_client
          Infrastructure::LlmClient.stub(:for, llm_client) do
            handler.call(request, headers)
          end
        else
          Infrastructure::LlmClient.stub(:for, stub_ok_llm) do
            handler.call(request, headers)
          end
        end
      end

      before do
        Tyla::Database::PromptLogOrm.dataset = HTCS_DB[:prompt_logs]
        HTCS_DB[:prompt_logs].delete
      end

      # ── (a/b) Header validation ──────────────────────────────────────────────

      it '(a) returns Failure[:unauthorized] when X-LLM-Provider header is missing' do
        headers  = VALID_HEADERS.reject { |k, _| k == 'X-LLM-Provider' }
        handler  = HandleTutorChat.new(rate_limiter: fresh_rate_limiter)
        outcome  = handler.call(VALID_REQUEST, headers)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :unauthorized
        _(outcome.failure.last).must_include 'X-LLM-Provider'
      end

      it '(b) returns Failure[:unauthorized] when X-LLM-Key header is missing' do
        headers  = VALID_HEADERS.reject { |k, _| k == 'X-LLM-Key' }
        handler  = HandleTutorChat.new(rate_limiter: fresh_rate_limiter)
        outcome  = handler.call(VALID_REQUEST, headers)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :unauthorized
        _(outcome.failure.last).must_include 'X-LLM-Key'
      end

      # ── (c) Rate limiting ────────────────────────────────────────────────────

      it '(c) returns Failure[:rate_limited] when rate limit is exhausted' do
        rl      = fresh_rate_limiter
        limit   = Values::RateLimitPolicy::MAX_REQUESTS_PER_MINUTE
        student = VALID_REQUEST[:student_id]
        limit.times { rl.check!(student) }

        handler = HandleTutorChat.new(rate_limiter: rl)
        outcome = Infrastructure::LlmClient.stub(:for, stub_ok_llm) do
          handler.call(VALID_REQUEST, VALID_HEADERS)
        end
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :rate_limited
      end

      # ── (d) Pending row written before LLM call ──────────────────────────────

      it '(d) writes a pending DB row (attack_probability/evaluation nil) before calling the LLM' do
        call_log = []

        # LLM client records when it's first called; at that point we check DB
        pending_row = nil
        tracking_client = Object.new
        tracking_client.define_singleton_method(:send_prompt) do |**_|
          # Read back the row that should already exist as pending
          pending_row = HTCS_DB[:prompt_logs].first
          call_log << :llm_called
          Infrastructure::LlmResponse.new(content: 'reply', usage: { input_tokens: 1, output_tokens: 1 })
        end

        Infrastructure::LlmClient.stub(:for, tracking_client) do
          HandleTutorChat.new(rate_limiter: fresh_rate_limiter).call(VALID_REQUEST, VALID_HEADERS)
        end

        _(call_log).wont_be_empty
        _(pending_row).wont_be_nil
        _(pending_row[:attack_probability]).must_be_nil
        _(pending_row[:evaluation]).must_be_nil
      end

      # ── (e) Row back-filled after orchestrator returns ───────────────────────

      it '(e) back-fills attack_probability and evaluation after the orchestrator returns' do
        # Use a stub whose guard JSON is well-formed so back-fill writes real values.
        call_with(llm_client: stub_refused_guard_llm)
        row = HTCS_DB[:prompt_logs].first
        _(row).wont_be_nil
        _(row[:attack_probability]).must_be_close_to 0.9
        _(row[:evaluation]).must_equal 'jailbreak'
      end

      # ── (f) X-LLM-Key never in DB ────────────────────────────────────────────

      it '(f) X-LLM-Key value never appears in any DB column' do
        api_key = 'sk-super-secret-key'
        call_with(headers: VALID_HEADERS.merge('X-LLM-Key' => api_key))

        row = HTCS_DB[:prompt_logs].first
        _(row).wont_be_nil
        row.each_value do |val|
          _(val.to_s).wont_include(api_key) if val
        end
      end

      # ── (g) Orchestrator Failure propagated without DB update ────────────────

      it '(g) propagates Orchestrator Failure without updating the DB row' do
        # Trigger Failure[:bad_mode] via an unknown mode
        bad_request = VALID_REQUEST.merge(mode: 'completely-invalid')
        # Guard fails open (no key in LLM), orchestrator raises ArgumentError
        outcome = Infrastructure::LlmClient.stub(:for, stub_ok_llm) do
          HandleTutorChat.new(rate_limiter: fresh_rate_limiter).call(bad_request, VALID_HEADERS)
        end

        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_mode

        # The pending row is created before orch.call, but the back-fill never
        # runs on Failure — attack_probability / evaluation stay nil.
        row = HTCS_DB[:prompt_logs].first
        _(row).wont_be_nil
        _(row[:attack_probability]).must_be_nil
        _(row[:evaluation]).must_be_nil
      end

      # ── Structured log does not contain API key ───────────────────────────────

      it 'structured log output contains student_id and status but not the API key' do
        api_key = 'sk-logged-key-xyz'
        log_output = StringIO.new
        orig_stdout = $stdout
        $stdout = log_output

        Infrastructure::LlmClient.stub(:for, stub_ok_llm) do
          HandleTutorChat.new(rate_limiter: fresh_rate_limiter)
            .call(VALID_REQUEST, VALID_HEADERS.merge('X-LLM-Key' => api_key))
        end
      ensure
        $stdout = orig_stdout
        output = log_output.string
        _(output).must_include VALID_REQUEST[:student_id]
        _(output).wont_include api_key
      end
    end
  end
end
