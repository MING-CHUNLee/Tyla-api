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
  app/infrastructure/filesystem/tutor_chat/assignment_loader.rb
  app/infrastructure/filesystem/tutor_chat/solution_loader.rb
  app/infrastructure/filesystem/tutor_chat/student_file_loader.rb
  app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb
  app/infrastructure/filesystem/tutor_chat/refusal_loader.rb
  app/presentation/representers/tutor_chat_representer.rb
  app/application/services/tutor_chat/run_tutor_chat.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Services
    describe RunTutorChat do
      include Dry::Monads[:result]

      PROMPT = 'Why is FD least sensitive to outliers?'

      let(:valid_headers) do
        {
          'HTTP_X_LLM_PROVIDER' => 'openai',
          'HTTP_X_LLM_KEY'      => 'sk-test-key-abc'
        }
      end

      # Seed a guard-pass row directly into the in-memory table and return its id.
      def seed_guard(attack_probability:, prompt: PROMPT, evaluation: 'ok')
        RTC_DB[:prompt_logs].insert(
          course_id:          'CSDS',
          project_id:         'HW2',
          student_id:         'stu-abc',
          prompt:             prompt,
          attack_probability: attack_probability,
          evaluation:         evaluation
        )
      end

      def request_for(guard_log_id, **overrides)
        {
          course_id:    'CSDS',
          project_id:   'HW2',
          student_id:   'stu-abc',
          guard_log_id: guard_log_id,
          prompt:       PROMPT
        }.merge(overrides)
      end

      # Only the tutor LLM is called now — no guard arm. `rate_limit` defaults to
      # the empty bag (backward-compatible: existing tests build no rate-limit headers).
      def tutor_llm(content: 'tutor reply', usage: { input_tokens: 10, output_tokens: 5 }, rate_limit: {})
        call_log = []
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          call_log << kwargs
          Infrastructure::LlmResponse.new(content: content, usage: usage, rate_limit: rate_limit)
        end
        client.define_singleton_method(:calls) { call_log }
        client
      end

      def raising_tutor(error_class, message = 'boom')
        client = Object.new
        client.define_singleton_method(:send_prompt) { |**_kwargs| raise error_class, message }
        client.define_singleton_method(:calls) { [] }
        client
      end

      # Tutor client whose send_prompt raises a provider 429 (LlmError::RateLimited),
      # carrying an explicit retry_after and rate-limit header bag.
      def rate_limited_tutor(retry_after: '30', rate_limit: { 'x-ratelimit-remaining-requests' => '0' })
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_kwargs|
          raise Infrastructure::LlmError::RateLimited.new(
            'rate limited', retry_after: retry_after, rate_limit: rate_limit
          )
        end
        client.define_singleton_method(:calls) { [] }
        client
      end

      def call_with(llm_client:, request:, headers: nil)
        headers ||= valid_headers
        Infrastructure::LlmClient.stub(:for, llm_client) do
          RunTutorChat.new.call(request, headers)
        end
      end

      before do
        Tyla::Database::PromptLogOrm.dataset = RTC_DB[:prompt_logs]
        RTC_DB[:prompt_logs].delete
      end

      it 'returns Failure[:forbidden] when X-LLM-Key is missing' do
        id      = seed_guard(attack_probability: 0.1)
        outcome = RunTutorChat.new.call(request_for(id), valid_headers.except('HTTP_X_LLM_KEY'))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :forbidden
      end

      it 'returns Failure[:bad_request] when the body is missing prompt' do
        id      = seed_guard(attack_probability: 0.1)
        bad     = request_for(id).except(:prompt)
        outcome = call_with(request: bad, llm_client: tutor_llm)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
      end

      it 'returns Failure[:bad_request] when guard_log_id is missing' do
        seed_guard(attack_probability: 0.1)
        bad     = request_for(1).except(:guard_log_id)
        outcome = call_with(request: bad, llm_client: tutor_llm)
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
      end

      it 'done path: verifies guard_log_id, calls the tutor once, usage is tutor-only, actions default []' do
        id      = seed_guard(attack_probability: 0.1)
        client  = tutor_llm(content: 'Step 1: ...', usage: { input_tokens: 10, output_tokens: 5 })
        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome).must_be :success?
        kind, dto = outcome.value!
        _(kind).must_equal :done
        _(dto.status).must_equal 'done'
        _(dto.content).must_equal 'Step 1: ...'
        _(dto.actions).must_equal []
        _(dto.usage).must_equal(input_tokens: 10, output_tokens: 5)  # tutor-only
        _(client.calls.size).must_equal 1                            # tutor only, no guard
      end

      it 'unavailable path: a fail-open guard row (nil probability) still calls the tutor' do
        id      = seed_guard(attack_probability: nil)
        client  = tutor_llm(content: 'fallback reply')
        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome).must_be :success?
        kind, dto = outcome.value!
        _(kind).must_equal :unavailable
        _(dto.status).must_equal 'unavailable'
        _(dto.content).must_equal 'fallback reply'
        _(client.calls.size).must_equal 1
      end

      it 'forbidden path: a forbidden guard row (>= 0.7) skips the tutor and returns a refusal DTO' do
        id      = seed_guard(attack_probability: 0.95)
        client  = tutor_llm
        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome).must_be :success?
        kind, dto = outcome.value!
        _(kind).must_equal :forbidden
        _(dto.status).must_equal 'forbidden'
        _(dto.content).must_include "Let's work through this together"
        _(dto.usage).must_be_nil
        _(dto.actions).must_be_nil
        _(client.calls.size).must_equal 0  # tutor never called
      end

      it 'forbidden path: an unknown guard_log_id is refused without a tutor call' do
        client  = tutor_llm
        outcome = call_with(request: request_for(999_999), llm_client: client)

        _(outcome).must_be :success?
        kind, dto = outcome.value!
        _(kind).must_equal :forbidden
        _(dto.usage).must_be_nil
        _(client.calls.size).must_equal 0
      end

      it 'forbidden path: a prompt mismatch is refused without a tutor call' do
        id      = seed_guard(attack_probability: 0.1, prompt: 'a different, earlier prompt')
        client  = tutor_llm
        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome).must_be :success?
        kind, = outcome.value!
        _(kind).must_equal :forbidden
        _(client.calls.size).must_equal 0
      end

      it 'parses an <actions> block out of the tutor reply: content is prose, actions is the parsed array' do
        id    = seed_guard(attack_probability: 0.1)
        reply = "Here is a hint.\n<actions>[{\"type\":\"load_file\",\"path\":\"hw11.R\"}]</actions>"
        outcome = call_with(request: request_for(id), llm_client: tutor_llm(content: reply))

        _, dto = outcome.value!
        _(dto.content).must_equal 'Here is a hint.'
        _(dto.actions).must_equal [{ 'type' => 'load_file', 'path' => 'hw11.R' }]
      end

      it 'tool_calls path: uses tool_calls from LlmResponse when present, skipping TutorReplyParser' do
        id         = seed_guard(attack_probability: 0.1)
        tool_call  = { 'type' => 'edit_file', 'path' => 'hw2.R',
                       'patches' => [{ 'search' => 'old', 'replace' => 'new' }] }
        llm_client = Object.new
        llm_client.define_singleton_method(:send_prompt) do |**_kwargs|
          Infrastructure::LlmResponse.new(
            content:    'Here is the fix.',
            usage:      { input_tokens: 20, output_tokens: 10 },
            tool_calls: [tool_call]
          )
        end

        outcome = call_with(request: request_for(id), llm_client: llm_client)

        _, dto = outcome.value!
        _(dto.content).must_equal 'Here is the fix.'
        _(dto.actions).must_equal [tool_call]
      end

      it 'malformed actions JSON: drops actions but keeps the prose' do
        id    = seed_guard(attack_probability: 0.1)
        reply = "Prose stays.\n<actions>[broken json}</actions>"
        outcome = call_with(request: request_for(id), llm_client: tutor_llm(content: reply))

        _, dto = outcome.value!
        _(dto.content).must_equal 'Prose stays.'
        _(dto.actions).must_equal []
      end

      # ── Hybrid lazy solution mini-loop (plan 2026-06-11) ─────────────────────

      # Client that replays a fixed script of responses (one per call) and
      # records every send_prompt kwargs for inspection.
      def scripted_llm(*responses)
        call_log = []
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          call_log << kwargs
          responses.fetch(call_log.size - 1)
        end
        client.define_singleton_method(:calls) { call_log }
        client
      end

      def load_reference_reply(extra_tool_calls: [], content: 'Let me consult the reference.')
        Infrastructure::LlmResponse.new(
          content:    content,
          usage:      { input_tokens: 10, output_tokens: 5 },
          tool_calls: [{ 'type' => 'load_reference', 'name' => 'reference_solution' }] + extra_tool_calls
        )
      end

      it 'mini-loop: load_reference triggers round 2 with the solution injected and the tool removed; usage = Σ' do
        id     = seed_guard(attack_probability: 0.1)
        final  = Infrastructure::LlmResponse.new(content: 'Compare your binwidths.',
                                                 usage: { input_tokens: 40, output_tokens: 20 })
        client = scripted_llm(load_reference_reply, final)

        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome).must_be :success?
        _, dto = outcome.value!
        _(client.calls.size).must_equal 2

        round1_tools = client.calls[0][:tools].map { |t| t[:name] }
        round2_tools = client.calls[1][:tools].map { |t| t[:name] }
        _(round1_tools).must_include 'load_reference'
        _(round2_tools).wont_include 'load_reference'           # structural termination
        _(round2_tools).must_include 'edit_file'                # other tools survive

        _(client.calls[0][:system_prompt]).wont_include '## Reference Solution'
        _(client.calls[1][:system_prompt]).must_include '## Reference Solution'
        _(client.calls[1][:system_prompt]).must_include 'included below'  # loaded-manifest variant

        _(dto.content).must_equal 'Compare your binwidths.'     # round-1 prose discarded
        _(dto.usage).must_equal(input_tokens: 50, output_tokens: 25)
        _(dto.warnings).must_include 'reference_loaded'
      end

      it 'mini-loop: solution content and load_reference never appear in the serialized response' do
        id     = seed_guard(attack_probability: 0.1)
        final  = Infrastructure::LlmResponse.new(content: 'Here is a hint.',
                                                 usage: { input_tokens: 40, output_tokens: 20 })
        client = scripted_llm(load_reference_reply, final)

        _, dto = call_with(request: request_for(id), llm_client: client).value!

        solution = Infrastructure::Filesystem::SolutionLoader.load('HW2')
        marker   = solution.lines.map(&:strip).find { |line| line.length > 20 }
        json     = Representer::TutorChat.new(dto).to_json
        _(marker).wont_be_nil                       # fixture sanity
        _(json).wont_include marker                 # solution never leaves the server
        _(json).wont_include 'load_reference'       # the tool's existence stays server-side
      end

      it 'mini-loop: load_reference + edit_file in round 1 → load wins, the round-1 edit never leaks (B3 §4.5)' do
        id   = seed_guard(attack_probability: 0.1)
        edit = { 'type' => 'edit_file', 'path' => 'hw2.R',
                 'patches' => [{ 'search' => 'ROUND1_LEAK', 'replace' => 'x' }] }
        round2_action = { 'type' => 'execute_script', 'code' => 'hist(x)' }
        final = Infrastructure::LlmResponse.new(content: 'Re-decided with the reference.',
                                                usage: { input_tokens: 30, output_tokens: 10 },
                                                tool_calls: [round2_action])
        client = scripted_llm(load_reference_reply(extra_tool_calls: [edit]), final)

        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(client.calls.size).must_equal 2
        _(dto.actions).must_equal [round2_action]   # round-2 re-decision only
        _(dto.content).wont_include 'ROUND1_LEAK'
      end

      it 'mini-loop: an XML-fallback <actions> load_reference also triggers round 2 (non-tool_use providers)' do
        id    = seed_guard(attack_probability: 0.1)
        xml   = "Checking.\n<actions>[{\"type\":\"load_reference\",\"name\":\"reference_solution\"}]</actions>"
        final = Infrastructure::LlmResponse.new(content: 'Answer with reference.',
                                                usage: { input_tokens: 40, output_tokens: 20 })
        client = scripted_llm(
          Infrastructure::LlmResponse.new(content: xml, usage: { input_tokens: 10, output_tokens: 5 }),
          final
        )

        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(client.calls.size).must_equal 2
        _(dto.content).must_equal 'Answer with reference.'
        _(dto.warnings).must_include 'reference_loaded'
      end

      it 'mini-loop: a hallucinated terminal-round load_reference is filtered from actions, loop does not re-enter' do
        id    = seed_guard(attack_probability: 0.1)
        # Round 2 is structurally tool-less for load_reference, but the XML path
        # is free text — the model can still hallucinate it there.
        xml   = "Done.\n<actions>[{\"type\":\"load_reference\",\"name\":\"reference_solution\"}," \
                '{"type":"execute_script","code":"hist(x)"}]</actions>'
        client = scripted_llm(
          load_reference_reply,
          Infrastructure::LlmResponse.new(content: xml, usage: { input_tokens: 40, output_tokens: 20 })
        )

        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(client.calls.size).must_equal 2           # terminal round never re-enters the loop
        _(dto.content).must_equal 'Done.'
        _(dto.actions).must_equal [{ 'type' => 'execute_script', 'code' => 'hist(x)' }]
      end

      it 'mini-loop: a round-2 timeout surfaces as the existing :upstream_timeout failure' do
        id     = seed_guard(attack_probability: 0.1)
        count  = 0
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_kwargs|
          count += 1
          raise Infrastructure::LlmError::Timeout, 'boom' if count > 1

          Infrastructure::LlmResponse.new(content: 'r1', usage: { input_tokens: 1, output_tokens: 1 },
                                          tool_calls: [{ 'type' => 'load_reference', 'name' => 'reference_solution' }])
        end

        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :upstream_timeout
      end

      it 'mini-loop: a turn that never requests the reference stays a single call with no reference_loaded warning' do
        id      = seed_guard(attack_probability: 0.1)
        client  = tutor_llm(content: 'plain answer')
        _, dto  = call_with(request: request_for(id), llm_client: client).value!

        _(client.calls.size).must_equal 1
        _(dto.warnings).must_be_nil
      end

      it 'persists a tutor-turn row carrying forward the guard probability + evaluation' do
        id = seed_guard(attack_probability: 0.2, evaluation: 'normal')
        call_with(request: request_for(id), llm_client: tutor_llm)

        # Two rows now: the seeded guard row and the new tutor-turn row.
        turn = RTC_DB[:prompt_logs].order(:id).last
        _(turn[:attack_probability]).must_be_close_to 0.2
        _(turn[:evaluation]).must_equal 'normal'
        _(turn[:prompt]).must_equal PROMPT
      end

      it 'returns Failure[:upstream_timeout] when the tutor LLM times out' do
        id      = seed_guard(attack_probability: 0.1)
        outcome = call_with(request: request_for(id), llm_client: raising_tutor(Infrastructure::LlmError::Timeout))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :upstream_timeout
      end

      it 'returns Failure[:upstream_error] when the tutor LLM upstream fails' do
        id      = seed_guard(attack_probability: 0.1)
        outcome = call_with(request: request_for(id),
                            llm_client: raising_tutor(Infrastructure::LlmError::Upstream,
                                                      'HTTP 503'))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :upstream_error
      end

      # ── Provider rate-limit (plan 2026-06-18 route C1) ───────────────────────

      it 'returns Failure[:rate_limited] with retry_after + provider_account scope on a 429' do
        id      = seed_guard(attack_probability: 0.1)
        outcome = call_with(request: request_for(id), llm_client: rate_limited_tutor(retry_after: '42'))

        _(outcome).must_be :failure?
        tag, _message, errors = outcome.failure
        _(tag).must_equal :rate_limited
        _(errors[:retry_after]).must_equal '42'
        _(errors[:limit_scope]).must_equal 'provider_account'
      end

      it 'labels the 429 limit_dimension as "requests" from a remaining-requests header' do
        id      = seed_guard(attack_probability: 0.1)
        client  = rate_limited_tutor(rate_limit: { 'x-ratelimit-remaining-requests' => '0' })
        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome.failure[2][:limit_dimension]).must_equal 'requests'
      end

      it 'falls back to limit_dimension "unknown" when only Retry-After is present (no remaining header)' do
        id      = seed_guard(attack_probability: 0.1)
        client  = rate_limited_tutor(rate_limit: { 'retry-after' => '30' })
        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome.failure[2][:limit_dimension]).must_equal 'unknown'
      end

      it 'mini-loop: a round-2 429 surfaces as the :rate_limited failure' do
        id     = seed_guard(attack_probability: 0.1)
        count  = 0
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_kwargs|
          count += 1
          if count > 1
            raise Infrastructure::LlmError::RateLimited.new(
              'rate limited', retry_after: '30', rate_limit: { 'x-ratelimit-remaining-requests' => '0' }
            )
          end

          Infrastructure::LlmResponse.new(content: 'r1', usage: { input_tokens: 1, output_tokens: 1 },
                                          tool_calls: [{ 'type' => 'load_reference', 'name' => 'reference_solution' }])
        end

        outcome = call_with(request: request_for(id), llm_client: client)

        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :rate_limited
      end

      # ── tripped_rate_limit_dimension unit (shared by hard 429 + C2 soft path) ──

      def dimension_for(bag)
        RunTutorChat.new.send(:tripped_rate_limit_dimension, bag)
      end

      it 'tripped_rate_limit_dimension: infers "requests" from a low remaining-requests field' do
        _(dimension_for('x-ratelimit-remaining-requests' => '0')).must_equal 'requests'
      end

      it 'tripped_rate_limit_dimension: infers "tokens" from a low remaining-tokens field' do
        _(dimension_for('x-ratelimit-remaining-tokens' => '1')).must_equal 'tokens'
      end

      it 'tripped_rate_limit_dimension: when both axes are low it picks the smaller value\'s axis' do
        _(dimension_for('x-ratelimit-remaining-requests' => '2',
                        'x-ratelimit-remaining-tokens'   => '0')).must_equal 'tokens'
      end

      it 'tripped_rate_limit_dimension: a low remaining field with no request/token word is "unknown"' do
        _(dimension_for('x-ratelimit-remaining' => '0')).must_equal 'unknown'
      end

      it 'tripped_rate_limit_dimension: returns nil when remaining is well above the floor' do
        _(dimension_for('x-ratelimit-remaining-requests' => '500')).must_be_nil
      end

      it 'tripped_rate_limit_dimension: returns nil for an empty bag (unknown channel / no header)' do
        _(dimension_for({})).must_be_nil
      end

      it 'round-1 system prompt embeds persona, assignment, manifest and student file — but NOT the solution' do
        id       = seed_guard(attack_probability: 0.05)
        captured = nil
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          captured = kwargs
          Infrastructure::LlmResponse.new(content: 'ok', usage: {})
        end

        call_with(request: request_for(id), llm_client: client)

        _(captured).wont_be_nil
        prompt = captured[:system_prompt]
        _(prompt).must_include 'Tutor-Guide Mode'              # persona
        _(prompt).must_include '## Assignment'                 # assignment header
        _(prompt).must_include '## Available Course Materials' # manifest (eager)
        _(prompt).wont_include '## Reference Solution'         # solution is lazy now
        _(prompt).must_include 'Hw2.Rmd'                       # student file
        _(prompt).must_include '## Tool Use Guide'             # tool use decision rules
        _(captured[:user_message]).must_equal PROMPT
      end

      it 'fills warnings with file_context_dropped when the live workspace exceeds the budget (§2.7)' do
        id   = seed_guard(attack_probability: 0.1)
        huge = 'x' * 40_000   # ~10K tokens ≫ the 8K unknown-channel input budget → whole-block drop
        outcome = call_with(request: request_for(id, file_context: huge), llm_client: tutor_llm)

        _, dto = outcome.value!
        _(dto.warnings).must_equal ['file_context_dropped']
      end

      it 'fills warnings with history_truncated when older turns are dropped (§2.7)' do
        id      = seed_guard(attack_probability: 0.1)
        history = [
          { role: 'user', content: 'y' * 40_000 },   # too big to keep → dropped
          { role: 'assistant', content: 'short reply' }
        ]
        outcome = call_with(request: request_for(id, history: history), llm_client: tutor_llm)

        _, dto = outcome.value!
        _(dto.warnings).must_include 'history_truncated'
      end

      it 'leaves warnings nil on a normal turn (field then omitted by the representer)' do
        id      = seed_guard(attack_probability: 0.1)
        outcome = call_with(request: request_for(id), llm_client: tutor_llm)

        _, dto = outcome.value!
        _(dto.warnings).must_be_nil
      end

      # ── Session token limit (DEV feature 2026-06-16) ─────────────────────────

      it 'fills warnings with session_limit_reached when the input nears the channel cap' do
        id     = seed_guard(attack_probability: 0.1)
        # Unknown channel (test endpoint nil) → 8_000 input cap; 7_500 ≥ 0.9 × 8_000.
        client = tutor_llm(content: 'Wrapping up.', usage: { input_tokens: 7_500, output_tokens: 5 })
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(dto.warnings).must_include 'session_limit_reached'
      end

      it 'leaves session_limit_reached unset when the input is well under the cap' do
        id     = seed_guard(attack_probability: 0.1)
        client = tutor_llm(content: 'ok', usage: { input_tokens: 100, output_tokens: 5 })
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(Array(dto.warnings)).wont_include 'session_limit_reached'
      end

      it 'measures the terminal (round-2) input, not the cross-round Σ, for the session limit' do
        id    = seed_guard(attack_probability: 0.1)
        # Round 1 is small; round 2's own input (7_500) trips the 0.9 × 8_000 cap.
        # The Σ that becomes client `usage` is irrelevant to the check.
        final = Infrastructure::LlmResponse.new(content: 'Compare your binwidths.',
                                                usage: { input_tokens: 7_500, output_tokens: 20 })
        client = scripted_llm(load_reference_reply, final)
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(dto.warnings).must_include 'session_limit_reached'
        _(dto.warnings).must_include 'reference_loaded'
      end

      # ── Provider rate-limit soft warning (plan 2026-06-18 route C2) ──────────

      it 'fills warnings with provider_rate_limited when the terminal reply reports a low remaining axis' do
        id     = seed_guard(attack_probability: 0.1)
        client = tutor_llm(content: 'ok', rate_limit: { 'x-ratelimit-remaining-requests' => '0' })
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(dto.warnings).must_include 'provider_rate_limited'
      end

      it 'leaves provider_rate_limited unset when the remaining quota is well above the floor' do
        id     = seed_guard(attack_probability: 0.1)
        client = tutor_llm(content: 'ok', rate_limit: { 'x-ratelimit-remaining-requests' => '500' })
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(Array(dto.warnings)).wont_include 'provider_rate_limited'
      end

      it 'leaves provider_rate_limited unset for an empty bag (unknown channel / no header) — safe default' do
        id     = seed_guard(attack_probability: 0.1)
        client = tutor_llm(content: 'ok', rate_limit: {})
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(Array(dto.warnings)).wont_include 'provider_rate_limited'
      end

      it 'provider_rate_limited is orthogonal to session_limit_reached — both can fire on one turn' do
        id = seed_guard(attack_probability: 0.1)
        # 7_500 ≥ 0.9 × 8_000 (session) AND remaining-requests 0 ≤ floor (provider).
        client = tutor_llm(content: 'Wrapping up.',
                           usage: { input_tokens: 7_500, output_tokens: 5 },
                           rate_limit: { 'x-ratelimit-remaining-requests' => '0' })
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(dto.warnings).must_include 'session_limit_reached'
        _(dto.warnings).must_include 'provider_rate_limited'
      end

      it 'reads the terminal (round-2) rate_limit, not round 1 — Σ-usage fold does not clobber it' do
        id    = seed_guard(attack_probability: 0.1)
        # Round 1's bag is healthy; round 2 (the terminal reply) is throttled. The
        # warning must follow the terminal round, proving finish_loop's .with(usage:)
        # left reply.rate_limit intact.
        final = Infrastructure::LlmResponse.new(content: 'Compare your binwidths.',
                                                usage: { input_tokens: 40, output_tokens: 20 },
                                                rate_limit: { 'x-ratelimit-remaining-requests' => '0' })
        round1 = Infrastructure::LlmResponse.new(
          content:    'Let me consult the reference.',
          usage:      { input_tokens: 10, output_tokens: 5 },
          tool_calls: [{ 'type' => 'load_reference', 'name' => 'reference_solution' }],
          rate_limit: { 'x-ratelimit-remaining-requests' => '500' }
        )
        client = scripted_llm(round1, final)
        _, dto = call_with(request: request_for(id), llm_client: client).value!

        _(client.calls.size).must_equal 2
        _(dto.warnings).must_include 'provider_rate_limited'
        _(dto.warnings).must_include 'reference_loaded'
      end

      it 'fills warnings with workspace_overview_dropped when the overview exceeds the budget' do
        id   = seed_guard(attack_probability: 0.1)
        huge = 'o' * 40_000   # ≫ the unknown-channel input budget → whole-block drop
        outcome = call_with(request: request_for(id, workspace_overview: huge), llm_client: tutor_llm)

        _, dto = outcome.value!
        _(dto.warnings).must_include 'workspace_overview_dropped'
      end

      # ── Workspace edit gate (plan 2026-06-12 §2.2) ───────────────────────────

      # `patches` accepts a custom shape so tests can exercise the normalizer
      # (a model pasting an "N| " prefix into `search`) vs. the clean new shape.
      def edit_file_tool(path, patches: [{ 'start_line' => 69, 'search' => 'old', 'replace' => 'new' }])
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_kwargs|
          Infrastructure::LlmResponse.new(
            content:    'Fixing it.',
            usage:      { input_tokens: 10, output_tokens: 5 },
            tool_calls: [{ 'type' => 'edit_file', 'path' => path, 'patches' => patches }]
          )
        end
        client.define_singleton_method(:calls) { [] }
        client
      end

      it 'gate: with workspace_overview, an edit_file for an unloaded path is rewritten to load_file' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id,
                              workspace_overview: 'R scripts (.R): hw2.R',
                              file_context:       "## File Contents\n### other.R\n  1| x <- 1")
        outcome = call_with(request: request, llm_client: edit_file_tool('hw2.R'))

        _, dto = outcome.value!
        _(dto.actions).must_equal [{ 'type' => 'load_file', 'path' => 'hw2.R' }]
        _(dto.warnings).must_include 'edit_file_redirected'
      end

      it 'gate: an edit_file whose path IS loaded passes through (start_line preserved) and does not warn' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id,
                              workspace_overview: 'R scripts (.R): hw2.R',
                              file_context:       "## File Contents\n### hw2.R\n  69| old")
        outcome = call_with(request: request, llm_client: edit_file_tool('hw2.R'))

        _, dto = outcome.value!
        _(dto.actions).must_equal [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                                     'patches' => [{ 'start_line' => 69, 'search' => 'old', 'replace' => 'new' }] }]
        _(dto.warnings).must_be_nil
      end

      it 'normalizer: an "N| " prefix the model pasted into search/replace is stripped on the wire' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id,
                              workspace_overview: 'R scripts (.R): hw2.R',
                              file_context:       "## File Contents\n### hw2.R\n  69| old")
        dirty   = [{ 'start_line' => 69, 'search' => '69| old', 'replace' => ' 69| new' }]
        outcome = call_with(request: request, llm_client: edit_file_tool('hw2.R', patches: dirty))

        _, dto = outcome.value!
        _(dto.actions).must_equal [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                                     'patches' => [{ 'start_line' => 69, 'search' => 'old', 'replace' => 'new' }] }]
      end

      it 'gate (regression): without workspace_overview the gate is inert — edit passes through' do
        id      = seed_guard(attack_probability: 0.1)
        # file_context does NOT contain hw2.R, but the gate must not fire: no overview marker.
        request = request_for(id, file_context: "## File Contents\n### other.R\n  1| x <- 1")
        outcome = call_with(request: request, llm_client: edit_file_tool('hw2.R'))

        _, dto = outcome.value!
        _(dto.actions).must_equal [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                                     'patches' => [{ 'start_line' => 69, 'search' => 'old', 'replace' => 'new' }] }]
        _(dto.warnings).must_be_nil
      end

      it 'file_context injects a live workspace block and suppresses the fixture student file' do
        id       = seed_guard(attack_probability: 0.05)
        captured = nil
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          captured = kwargs
          Infrastructure::LlmResponse.new(content: 'ok', usage: {})
        end

        request = request_for(id, file_context: 'LIVE_WORKSPACE_FROM_FRONTEND')
        call_with(request: request, llm_client: client)

        prompt = captured[:system_prompt]
        _(prompt).must_include '## Student Workspace (live)'
        _(prompt).must_include 'LIVE_WORKSPACE_FROM_FRONTEND'
        _(prompt).wont_include '## Student Workspace Files'
      end

      # ── Redundant load gate (plan 2026-06-13 §3/§4.4) ────────────────────────

      # A client that emits a fixed `content` + `tool_calls` list, for driving the
      # gate chain with arbitrary action shapes.
      def tool_calls_llm(content:, tool_calls:)
        client = Object.new
        client.define_singleton_method(:send_prompt) do |**_kwargs|
          Infrastructure::LlmResponse.new(
            content: content, usage: { input_tokens: 10, output_tokens: 5 }, tool_calls: tool_calls
          )
        end
        client.define_singleton_method(:calls) { [] }
        client
      end

      it 'redundant-load gate: a load_file for an already-loaded path is dropped and warns' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
        client  = tool_calls_llm(content: 'Loading.', tool_calls: [{ 'type' => 'load_file', 'path' => 'hw2.R' }])
        outcome = call_with(request: request, llm_client: client)

        _, dto = outcome.value!
        _(dto.actions).must_equal []
        _(dto.warnings).must_include 'redundant_load_dropped'
      end

      it 'redundant-load gate: a load_file for an UNLOADED path survives even when the gate is active' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
        client  = tool_calls_llm(content: 'Loading.', tool_calls: [{ 'type' => 'load_file', 'path' => 'hw3.R' }])
        outcome = call_with(request: request, llm_client: client)

        _, dto = outcome.value!
        _(dto.actions).must_equal [{ 'type' => 'load_file', 'path' => 'hw3.R' }]
        _(dto.warnings).must_be_nil
      end

      it 'cross-gate ordering: content gate reload for a stale already-loaded edit survives the load gate' do
        id      = seed_guard(attack_probability: 0.1)
        # hw2.R IS loaded, but the edit's search content does NOT match the snapshot →
        # EditPatchContentGate rewrites it to load_file hw2.R. That reload is legitimate
        # and must survive: it is produced AFTER RedundantLoadGate already ran. If the
        # redundant-load gate ran last, it would wrongly drop this (path already loaded).
        request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
        stale   = [{ 'start_line' => 1, 'search' => 'WRONG CONTENT', 'replace' => 'x <- 99' }]
        client  = tool_calls_llm(content: 'Fixing.',
                                 tool_calls: [{ 'type' => 'edit_file', 'path' => 'hw2.R', 'patches' => stale }])
        outcome = call_with(request: request, llm_client: client)

        _, dto = outcome.value!
        _(dto.actions).must_equal [{ 'type' => 'load_file', 'path' => 'hw2.R' }]
        _(dto.warnings).must_include 'edit_file_redirected'
        _(dto.warnings).wont_include 'redundant_load_dropped'   # the model emitted no redundant load
      end

      it 'redundant-load gate: drops only the loaded path in a mixed reply, keeps the unloaded one' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
        client  = tool_calls_llm(content: 'Loading two.',
                                 tool_calls: [{ 'type' => 'load_file', 'path' => 'hw2.R' },
                                              { 'type' => 'load_file', 'path' => 'Hw2.Rmd' }])
        outcome = call_with(request: request, llm_client: client)

        _, dto = outcome.value!
        _(dto.actions).must_equal [{ 'type' => 'load_file', 'path' => 'Hw2.Rmd' }]
        _(dto.warnings).must_include 'redundant_load_dropped'
      end

      # ── Decision E: no empty content + empty actions turn (plan 2026-06-13 §2/§6 D1) ──

      it 'decision E: a reply with only redundant loads and no prose yields fallback prose, never blank' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
        # The trigger case: the model re-loads an already-loaded file and gives no prose.
        client  = tool_calls_llm(content: '', tool_calls: [{ 'type' => 'load_file', 'path' => 'hw2.R' }])
        outcome = call_with(request: request, llm_client: client)

        _, dto = outcome.value!
        _(dto.actions).must_equal []
        refute(dto.content.nil? || dto.content.strip.empty?)   # never content-empty + actions-empty
        _(dto.warnings).must_include 'redundant_load_dropped'
      end

      it 'decision E: leaves real prose untouched when actions are cleared' do
        id      = seed_guard(attack_probability: 0.1)
        request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
        client  = tool_calls_llm(content: 'Here is the explanation.',
                                 tool_calls: [{ 'type' => 'load_file', 'path' => 'hw2.R' }])
        outcome = call_with(request: request, llm_client: client)

        _, dto = outcome.value!
        _(dto.actions).must_equal []
        _(dto.content).must_equal 'Here is the explanation.'   # genuine prose preserved
      end

      # ── Option C: backend-owned history compression (plan 2026-06-15 §4.3 / Phase E) ──

      def turn(prompt:, prose: nil, context_headers: nil, actions: nil)
        { prompt: prompt, prose: prose, context_headers: context_headers, actions: actions }.compact
      end

      it 'session_turns: the backend compresses each turn into [user, assistant] history pairs' do
        id      = seed_guard(attack_probability: 0.1)
        client  = tutor_llm(content: 'ok')
        turns   = [turn(prompt: 'How do I fix the histogram?',
                        prose: 'Use a smaller binwidth.',
                        context_headers: "### hw2.R\n",
                        actions: [{ type: 'edit_file', path: 'hw2.R',
                                    patches: [{ start_line: 5, search: 'bins=30', replace: 'binwidth=2' }] }])]
        call_with(request: request_for(id, session_turns: turns), llm_client: client)

        history = client.calls.first[:history]
        roles   = history.map { |h| h[:role] || h['role'] }
        _(roles).must_equal %w[user assistant]

        user, assistant = history.map { |h| h[:content] || h['content'] }
        _(user).must_include 'How do I fix the histogram?'
        _(user).must_include 'Previously inspected'         # seen-path placeholder, contents omitted
        _(user).must_include 'hw2.R'
        _(assistant).must_include 'Use a smaller binwidth.'  # terminal prose preserved
        _(assistant).must_include 'Suggested editing'        # neutral (proposal) edit wording
      end

      it 'session_turns: takes precedence over a legacy history array when both are sent' do
        id     = seed_guard(attack_probability: 0.1)
        client = tutor_llm(content: 'ok')
        turns  = [turn(prompt: 'earlier question', prose: 'earlier answer')]
        legacy = [{ role: 'user', content: 'LEGACY_SHOULD_NOT_APPEAR' }]
        call_with(request: request_for(id, session_turns: turns, history: legacy), llm_client: client)

        contents = client.calls.first[:history].map { |h| h[:content] || h['content'] }.join("\n")
        _(contents).must_include 'earlier question'
        _(contents).wont_include 'LEGACY_SHOULD_NOT_APPEAR'
      end

      it 'session_turns: absent → the legacy history path is used unchanged (regression)' do
        id     = seed_guard(attack_probability: 0.1)
        client = tutor_llm(content: 'ok')
        legacy = [{ role: 'user', content: 'a real legacy turn' },
                  { role: 'assistant', content: 'a real legacy reply' }]
        call_with(request: request_for(id, history: legacy), llm_client: client)

        _(client.calls.first[:history]).must_equal legacy
      end

      it 'session_turns: a normal turn leaves history_truncated unset (compression keeps it small)' do
        id     = seed_guard(attack_probability: 0.1)
        turns  = [turn(prompt: 'short question', prose: 'short answer')]
        _, dto = call_with(request: request_for(id, session_turns: turns), llm_client: tutor_llm).value!

        _(Array(dto.warnings)).wont_include 'history_truncated'
      end

      it 'session_turns: the round-1 system prompt carries the staleness arbitration rule (§5.4)' do
        id       = seed_guard(attack_probability: 0.1)
        captured = nil
        client   = Object.new
        client.define_singleton_method(:send_prompt) do |**kwargs|
          captured = kwargs
          Infrastructure::LlmResponse.new(content: 'ok', usage: {})
        end
        turns = [turn(prompt: 'q', prose: 'a')]
        call_with(request: request_for(id, session_turns: turns), llm_client: client)

        _(captured[:system_prompt]).must_include 'source of truth'
      end
    end
  end
end
