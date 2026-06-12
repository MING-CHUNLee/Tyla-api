# frozen_string_literal: true

require 'dry/monads'
require 'dry/monads/do'

module Tyla
  module Services
    # Second leg of the guard → tutor pipeline. This route no longer re-runs the
    # guard LLM; instead it requires a `guard_log_id` from a prior /guard_checks
    # pass and verifies it against the DB (single read, no LLM call): the log
    # exists, its stored prompt matches this request's prompt, and its derived
    # verdict ∈ {done, unavailable}. On a pass it composes the tutor system
    # prompt from on-disk artefacts (Phase 1: fixture) plus the optional live
    # `file_context`, forwards to the tutor LLM, and parses any actions out of
    # the reply (via native tool_use for Anthropic, XML fallback for others).
    # `usage` is tutor-only; forbidden carries no tutor cost.
    #
    # Hybrid lazy solution (plan 2026-06-11 §2): the tutor call is a bounded
    # two-round mini-loop. Round 1 withholds the reference solution and offers
    # a server-side `load_reference` tool; if the model calls it, the backend
    # RE-ASSEMBLES the prompt with the solution injected and the tool removed
    # (no tool_result continuation — both LLM clients drop tool call ids, §1.1)
    # and calls again. Termination is structural: round 2 cannot re-request.
    # `load_reference` never reaches the client — it is consumed server-side
    # and defensively filtered from terminal actions.
    class RunTutorChat
      include Dry::Monads[:result]
      include Dry::Monads::Do

      LOAD_REFERENCE = 'load_reference'

      TOOLS = [
        {
          name: 'edit_file',
          description: 'Apply a search-replace patch to a file in the student workspace. ' \
                       'Use when the exact code to fix is visible in the workspace. ' \
                       'Workspace file contents are shown with a "N| " line-number prefix on every line.',
          input_schema: {
            type: 'object',
            properties: {
              path:    { type: 'string', description: 'Relative path to the file' },
              patches: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    search:  { type: 'string',
                               description: 'Exact lines to find, copied verbatim INCLUDING the ' \
                                            'leading "N| " line-number prefixes shown in the workspace context.' },
                    replace: { type: 'string', description: 'Replacement code WITHOUT line-number prefixes.' }
                  },
                  required: %w[search replace]
                }
              }
            },
            required: %w[path patches]
          }
        },
        {
          name: 'execute_script',
          description: 'Provide a read-only R demo script. Use when showing runnable example code ' \
                       'that does not exist in any workspace file. No file writes or package installs.',
          input_schema: {
            type: 'object',
            properties: {
              code: { type: 'string', description: 'R code to execute' }
            },
            required: %w[code]
          }
        },
        {
          name: 'load_file',
          description: 'Request the contents of a workspace file that was not included in the current context.',
          input_schema: {
            type: 'object',
            properties: {
              path: { type: 'string', description: 'Relative path to the file to load' }
            },
            required: %w[path]
          }
        },
        {
          name: LOAD_REFERENCE,
          description: 'Load an instructor course material into your context. ' \
                       'Resolved by the server; the material itself is never shown to the student verbatim.',
          input_schema: {
            type: 'object',
            properties: {
              # enum doubles as a schema-level whitelist: no path hallucination.
              name: { type: 'string', enum: ['reference_solution'] }
            },
            required: %w[name]
          }
        }
      ].freeze

      # Round 2 physically lacks load_reference — termination is structural,
      # not prompt-enforced.
      ROUND2_TOOLS = TOOLS.reject { |t| t[:name] == LOAD_REFERENCE }.freeze

      def call(raw_params, headers)
        credentials = yield extract_credentials(headers)
        params      = yield validate(raw_params)
        guard_log   = yield load_guard_log(params[:guard_log_id])
        log         = yield persist_turn(params, guard_log)
        verdict     = derive_verdict(guard_log, params)

        # guard_log missing, prompt mismatch, or derived verdict :forbidden → refuse, no tutor call
        return forbidden_outcome(log, params[:project_id]) unless tutor_allowed?(verdict)

        reply, assembled, reference_loaded = yield tutor_mini_loop(credentials, params)

        Success(ok_outcome(log, reply, verdict, assembled, reference_loaded: reference_loaded))
      end

      private

      # ── Steps (each returns a Result; the chain short-circuits on Failure) ──────

      def extract_credentials(headers)
        api_key = headers['HTTP_X_LLM_KEY'] || ENV.fetch('OPENAI_API_KEY', nil)
        return Failure[:forbidden, 'missing X-LLM-Key'] if api_key.nil? || api_key.empty?

        Success(
          provider: headers['HTTP_X_LLM_PROVIDER'] || ENV.fetch('LLM_PROVIDER', 'openai'),
          api_key:  api_key,
          model:    headers['HTTP_X_LLM_MODEL'],
          endpoint: headers['HTTP_X_LLM_ENDPOINT']
        )
      end

      def validate(raw_params)
        validated = Request::TutorChat.new.call(raw_params)
        return Failure[:bad_request, 'validation failed', validated.errors.to_h] unless validated.success?

        Success(validated.to_h)
      end

      def load_guard_log(guard_log_id)
        Success(Repository::PromptLogs.find(guard_log_id))
      rescue Sequel::Error
        Failure[:db_error, 'could not read guard log']
      end

      # The turn row carries forward the referenced guard row's verdict fields
      # (attack_probability + evaluation), since the guard no longer runs here
      # but the doc still persists them in prompt_logs. nil when guard_log absent.
      def persist_turn(params, guard_log)
        entity = Entity::PromptLog.new(
          id:                 nil,
          course_id:          params[:course_id],
          project_id:         params[:project_id],
          student_id:         params[:student_id],
          prompt:             params[:prompt],
          attack_probability: guard_log&.attack_probability,
          evaluation:         guard_log&.evaluation,
          created_at:         nil
        )
        Success(Repository::PromptLogs.create(entity))
      rescue Sequel::Error
        Failure[:db_error, 'could not write log entry']
      end

      # Bounded mini-loop (plan §2/§3): both rounds run inside this one step —
      # the guard verdict was derived before it, so round 2 needs no re-check
      # (same prompt, no HTTP boundary crossed). Returns
      # [terminal reply (usage = Σ rounds), terminal assembly, reference_loaded].
      def tutor_mini_loop(credentials, params)
        assembled = yield assemble_prompt(params, credentials[:endpoint], include_solution: false)
        round1    = yield request_tutor_reply(credentials, assembled, params, TOOLS)
        return finish_loop([round1], assembled, reference_loaded: false) unless wants_reference?(round1)

        # Round 1's prose (if any) is discarded by design (plan §4 D4): a reply
        # that asked for the reference is a draft, not an answer.
        assembled = yield assemble_prompt(params, credentials[:endpoint], include_solution: true)
        round2    = yield request_tutor_reply(credentials, assembled, params, ROUND2_TOOLS)
        finish_loop([round1, round2], assembled, reference_loaded: true)
      end

      def assemble_prompt(params, endpoint, include_solution:)
        assembled = Prompts::BudgetAwarePromptAssembler.call(
          persona:          Infrastructure::Filesystem::TutorPersonaLoader.load(params[:project_id]),
          assignment:       Infrastructure::Filesystem::AssignmentLoader.load(params[:project_id]),
          solution:         Infrastructure::Filesystem::SolutionLoader.load(params[:project_id]),
          student_file:     { path:    Infrastructure::Filesystem::StudentFileLoader::FILENAME,
                              content: Infrastructure::Filesystem::StudentFileLoader.load(params[:project_id]) },
          file_context:     params[:file_context],
          history:          params[:history],
          user_prompt:      params[:prompt],
          endpoint:         endpoint,
          include_solution: include_solution
        )
        return Failure[:context_overflow, 'prompt exceeds model context window'] if assembled.overflow?

        Success(assembled)
      rescue Errno::ENOENT => e
        Failure[:not_found, "missing artefact: #{e.message}"]
      end

      def request_tutor_reply(credentials, assembled, params, tools)
        llm = Infrastructure::LlmClient.for(
          provider: credentials[:provider],
          api_key:  credentials[:api_key],
          model:    credentials[:model],
          endpoint: credentials[:endpoint]
        )
        reply = llm.send_prompt(
          system_prompt: assembled.system_prompt,
          user_message:  params[:prompt],
          history:       assembled.history,
          max_tokens:    assembled.max_tokens,
          tools:         tools
        )
        Success(reply)
      rescue Infrastructure::LlmError::Timeout
        Failure[:upstream_timeout, 'LLM request timed out']
      rescue Infrastructure::LlmError::Upstream => e
        Failure[:upstream_error, e.message]
      end

      # ── Plain helpers (no Result wrapping) ─────────────────────────────────────

      # Terminal packaging for the mini-loop: usage becomes Σ over all rounds
      # (the API's `usage` now means "all tutor calls this turn") and the
      # Phase 0 measurement line is emitted (plan §3 Step 4 — D1/D3 decision data).
      def finish_loop(rounds, assembled, reference_loaded:)
        reply = rounds.last
        reply = reply.with(usage: rounds.map(&:usage).reduce { |sum, u| sum_usage(sum, u) }) if rounds.size > 1
        log_phase0(rounds, reference_loaded)
        Success([reply, assembled, reference_loaded])
      end

      # Detection must cover BOTH parse paths (§1.3): native tool_calls and the
      # XML <actions> fallback — non-tool_use providers can also trigger round 2.
      def wants_reference?(reply)
        actions = if reply.tool_calls.any?
                    reply.tool_calls
                  else
                    Values::TutorReplyParser.call(reply.content).last
                  end
        actions.any? { |action| action_type(action) == LOAD_REFERENCE }
      end

      def action_type(action)
        action['type'] || action[:type]
      end

      def sum_usage(first, second)
        {
          input_tokens:  usage_count(first, :input_tokens) + usage_count(second, :input_tokens),
          output_tokens: usage_count(first, :output_tokens) + usage_count(second, :output_tokens)
        }
      end

      def usage_count(usage, key)
        (usage && (usage[key] || usage[key.to_s])).to_i
      end

      # Phase 0 measurement: rounds taken, whether the reference was loaded,
      # and per-round input tokens — the data behind the D1 (re-request rate)
      # and D3 (load rate vs. break-even) go/no-go calls. stderr, one line.
      def log_phase0(rounds, reference_loaded)
        return if ENV['RACK_ENV'] == 'test'

        inputs = rounds.map { |r| usage_count(r.usage, :input_tokens) }.join(',')
        warn "[tutor_chat.phase0] rounds=#{rounds.size} reference_loaded=#{reference_loaded} input_tokens=#{inputs}"
      end

      def derive_verdict(guard_log, params)
        return nil unless guard_log && guard_log.prompt == params[:prompt]

        Values::GuardLogVerdict.from(guard_log.attack_probability)
      end

      def tutor_allowed?(verdict)
        %i[done unavailable].include?(verdict)
      end

      # Terminal extraction. `load_reference` is consumed server-side and must
      # never reach the client (§1.3 — its mere presence reveals a solution
      # file exists): round 2 cannot emit it structurally, but the XML fallback
      # is free text and can hallucinate it, so filter defensively here.
      def extract_reply(llm_reply)
        prose, actions = if llm_reply.tool_calls.any?
                           [llm_reply.content, llm_reply.tool_calls]
                         else
                           Values::TutorReplyParser.call(llm_reply.content)
                         end
        [prose, actions.reject { |action| action_type(action) == LOAD_REFERENCE }]
      end

      # ── Outcome builders (return the [kind, dto] tuple the controller unwraps) ──

      # Forbidden is a *successful* business outcome, not an error — the controller
      # renders the refusal DTO at HTTP 200. The refusal artefact read can still
      # raise, so this returns a Result rather than a bare tuple.
      def forbidden_outcome(log, project_id)
        dto = Response::TutorChat.new(
          log_id:  log.id,
          status:  'forbidden',
          content: Infrastructure::Filesystem::RefusalLoader.load(project_id),
          actions: nil,        # omitted by the representer — never present on forbidden
          usage:   nil
        )
        Success([:forbidden, dto])
      rescue Errno::ENOENT => e
        Failure[:not_found, "missing artefact: #{e.message}"]
      end

      # §2.7: surface the assembler's trim flags instead of dropping silently —
      # the CLI renders these as status warnings so the student knows the tutor
      # did not see their file / older turns this round.
      def ok_outcome(log, reply, verdict, assembled, reference_loaded:)
        prose, actions = extract_reply(reply)
        warnings = []
        warnings << 'reference_loaded'     if reference_loaded
        warnings << 'file_context_dropped' if assembled.student_file_dropped
        warnings << 'history_truncated'    if assembled.history_turns_dropped.to_i.positive?
        dto = Response::TutorChat.new(
          log_id:   log.id,
          status:   verdict == :unavailable ? 'unavailable' : 'done',
          content:  prose,
          actions:  actions,    # [] when none
          usage:    reply.usage, # tutor-only; Σ over both rounds when the mini-loop ran
          warnings: warnings.empty? ? nil : warnings  # nil → field omitted by the representer
        )
        [verdict, dto]
      end
    end
  end
end
