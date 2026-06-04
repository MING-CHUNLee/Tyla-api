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
    # `file_context`, forwards to the tutor LLM, and parses any `<actions>` block
    # out of the reply. `usage` is tutor-only; forbidden carries no tutor cost.
    class RunTutorChat
      include Dry::Monads[:result]
      include Dry::Monads::Do

      def call(raw_params, headers)
        provider = headers['HTTP_X_LLM_PROVIDER'] || ENV.fetch('LLM_PROVIDER', 'openai')
        api_key  = headers['HTTP_X_LLM_KEY']      || ENV.fetch('OPENAI_API_KEY', nil)
        return Failure[:forbidden, 'missing X-LLM-Key'] if api_key.nil? || api_key.empty?

        model    = headers['HTTP_X_LLM_MODEL']
        endpoint = headers['HTTP_X_LLM_ENDPOINT']

        validated = Request::TutorChat.new.call(raw_params)
        return Failure[:bad_request, 'validation failed', validated.errors.to_h] unless validated.success?

        params = validated.to_h

        guard_log = Repository::PromptLogs.find(params[:guard_log_id])
        verdict   = guard_log && guard_log.prompt == params[:prompt] &&
                    Values::GuardLogVerdict.from(guard_log.attack_probability)

        # guard_log missing, prompt mismatch, or derived verdict :forbidden → refuse, no tutor call
        unless %i[done unavailable].include?(verdict)
          log = persist_turn(params, guard_log)
          return Success([:forbidden, build_forbidden_response(log.id, params[:project_id])])
        end

        log = persist_turn(params, guard_log)

        llm = Infrastructure::LlmClient.for(provider: provider, api_key: api_key, model: model, endpoint: endpoint)

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

        llm_reply = llm.send_prompt(
          system_prompt: assembled.system_prompt,
          user_message:  params[:prompt],
          history:       assembled.history,
          max_tokens:    assembled.max_tokens
        )
        prose, actions = Values::TutorReplyParser.call(llm_reply.content)

        response = build_ok_response(log.id, prose, actions, llm_reply.usage, verdict: verdict)
        Success([verdict, response])
      rescue Infrastructure::LlmError::Timeout
        Failure[:upstream_timeout, 'LLM request timed out']
      rescue Infrastructure::LlmError::Upstream => e
        Failure[:upstream_error, e.message]
      rescue Errno::ENOENT => e
        Failure[:not_found, "missing artefact: #{e.message}"]
      rescue Sequel::Error
        Failure[:db_error, 'could not write log entry']
      end

      private

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
        Repository::PromptLogs.create(entity)
      end

      def build_forbidden_response(log_id, project_id)
        Response::TutorChat.new(
          log_id:  log_id,
          status:  'forbidden',
          content: Infrastructure::Filesystem::RefusalLoader.load(project_id),
          actions: nil,        # omitted by the representer — never present on forbidden
          usage:   nil
        )
      end

      def build_ok_response(log_id, prose, actions, usage, verdict:)
        Response::TutorChat.new(
          log_id:  log_id,
          status:  verdict == :unavailable ? 'unavailable' : 'done',
          content: prose,
          actions: actions,    # [] when none
          usage:   usage       # tutor-only
        )
      end
    end
  end
end
