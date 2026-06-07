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
    class RunTutorChat
      include Dry::Monads[:result]
      include Dry::Monads::Do

      TOOLS = [
        {
          name: 'edit_file',
          description: 'Apply a search-replace patch to a file in the student workspace. ' \
                       'Use when the exact code to fix is visible in the workspace.',
          input_schema: {
            type: 'object',
            properties: {
              path:    { type: 'string', description: 'Relative path to the file' },
              patches: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    search:  { type: 'string', description: 'Exact snippet to find (must be unambiguous)' },
                    replace: { type: 'string', description: 'Replacement snippet' }
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
        }
      ].freeze

      def call(raw_params, headers)
        credentials = yield extract_credentials(headers)
        params      = yield validate(raw_params)
        guard_log   = yield load_guard_log(params[:guard_log_id])
        log         = yield persist_turn(params, guard_log)
        verdict     = derive_verdict(guard_log, params)

        # guard_log missing, prompt mismatch, or derived verdict :forbidden → refuse, no tutor call
        return forbidden_outcome(log, params[:project_id]) unless tutor_allowed?(verdict)

        assembled = yield assemble_prompt(params, credentials[:endpoint])
        reply     = yield request_tutor_reply(credentials, assembled, params)

        Success(ok_outcome(log, reply, verdict))
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

      def assemble_prompt(params, endpoint)
        assembled = Prompts::BudgetAwarePromptAssembler.call(
          persona:      Infrastructure::Filesystem::TutorPersonaLoader.load(params[:project_id]),
          assignment:   Infrastructure::Filesystem::AssignmentLoader.load(params[:project_id]),
          solution:     Infrastructure::Filesystem::SolutionLoader.load(params[:project_id]),
          student_file: { path:    Infrastructure::Filesystem::StudentFileLoader::FILENAME,
                          content: Infrastructure::Filesystem::StudentFileLoader.load(params[:project_id]) },
          file_context: params[:file_context],
          history:      params[:history],
          user_prompt:  params[:prompt],
          endpoint:     endpoint
        )
        return Failure[:context_overflow, 'prompt exceeds model context window'] if assembled.overflow?

        Success(assembled)
      rescue Errno::ENOENT => e
        Failure[:not_found, "missing artefact: #{e.message}"]
      end

      def request_tutor_reply(credentials, assembled, params)
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
          tools:         TOOLS
        )
        Success(reply)
      rescue Infrastructure::LlmError::Timeout
        Failure[:upstream_timeout, 'LLM request timed out']
      rescue Infrastructure::LlmError::Upstream => e
        Failure[:upstream_error, e.message]
      end

      # ── Plain helpers (no Result wrapping) ─────────────────────────────────────

      def derive_verdict(guard_log, params)
        return nil unless guard_log && guard_log.prompt == params[:prompt]

        Values::GuardLogVerdict.from(guard_log.attack_probability)
      end

      def tutor_allowed?(verdict)
        %i[done unavailable].include?(verdict)
      end

      def extract_reply(llm_reply)
        if llm_reply.tool_calls.any?
          [llm_reply.content, llm_reply.tool_calls]
        else
          Values::TutorReplyParser.call(llm_reply.content)
        end
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

      def ok_outcome(log, reply, verdict)
        prose, actions = extract_reply(reply)
        dto = Response::TutorChat.new(
          log_id:  log.id,
          status:  verdict == :unavailable ? 'unavailable' : 'done',
          content: prose,
          actions: actions,    # [] when none
          usage:   reply.usage # tutor-only
        )
        [verdict, dto]
      end
    end
  end
end
