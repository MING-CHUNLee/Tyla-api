# frozen_string_literal: true

require 'dry/monads'
require 'dry/monads/do'

module Tyla
  module Services
    # Second leg of the guard → tutor pipeline. Re-runs the guard server-side
    # (defence in depth — even if /guard_checks already passed) and, on allow,
    # composes the tutor system prompt from on-disk artefacts (Phase 1: fixture)
    # and forwards to the tutor LLM.
    class RunTutorChat
      include Dry::Monads[:result]
      include Dry::Monads::Do

      LLM_UNAVAILABLE_EVALUATION = 'llm-unavailable'

      def call(raw_params, headers)
        provider = headers['HTTP_X_LLM_PROVIDER'] || ENV.fetch('LLM_PROVIDER', 'openai')
        api_key  = headers['HTTP_X_LLM_KEY']      || ENV['OPENAI_API_KEY']
        return Failure[:unauthorized, 'missing X-LLM-Key'] if api_key.nil? || api_key.empty?

        model    = headers['HTTP_X_LLM_MODEL']
        endpoint = headers['HTTP_X_LLM_ENDPOINT']

        validated = Request::TutorChat.new.call(raw_params)
        return Failure[:bad_request, 'validation failed', validated.errors.to_h] unless validated.success?

        params = validated.to_h

        llm   = Infrastructure::LlmClient.for(provider: provider, api_key: api_key, model: model, endpoint: endpoint)
        guard = GuardAgent.new(llm_client: llm)

        guard_result    = guard.check(prompt: params[:prompt], mode: nil)
        llm_unavailable = guard_result.probability.nil?

        log = persist_log(params, guard_result)

        if !llm_unavailable && !guard_result.allowed?
          return Success([:blocked, build_blocked_response(log.id, guard_result)])
        end

        assignment = Infrastructure::Filesystem::AssignmentLoader.load(params[:project_id])
        solution   = Infrastructure::Filesystem::SolutionLoader.load(params[:project_id])
        student    = Infrastructure::Filesystem::StudentFileLoader.load(params[:project_id])
        persona    = Infrastructure::Filesystem::TutorPersonaLoader.load(params[:project_id])

        system_prompt = Prompts::TutorSystemPrompt.build(
          policy_text:   persona,
          solution_text: "## Assignment\n#{assignment}\n\n## Reference Solution\n#{solution}",
          context_files: [{ path: Infrastructure::Filesystem::StudentFileLoader::FILENAME, content: student }]
        )
        history   = Prompts::TutorSystemPrompt.truncate_history(params[:history])
        llm_reply = llm.send_prompt(
          system_prompt: system_prompt,
          user_message:  params[:prompt],
          history:       history
        )

        response = build_ok_response(log.id, llm_reply, llm_unavailable: llm_unavailable)
        Success([llm_unavailable ? :llm_unavailable : :ok, response])
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

      def persist_log(params, guard_result)
        entity = Entity::PromptLog.new(
          id:                 nil,
          course_id:          params[:course_id],
          project_id:         params[:project_id],
          student_id:         params[:student_id],
          prompt:             params[:prompt],
          attack_probability: guard_result.probability&.fetch(:attack),
          evaluation:         guard_result.reason,
          created_at:         nil
        )
        Repository::PromptLogs.create(entity)
      end

      def build_blocked_response(log_id, guard_result)
        {
          log_id:             log_id,
          allowed:            false,
          attack_probability: guard_result.probability&.fetch(:attack),
          evaluation:         guard_result.reason,
          refusal:            Values::RefusalTemplates.for
        }
      end

      def build_ok_response(log_id, llm_reply, llm_unavailable:)
        payload = {
          log_id:  log_id,
          allowed: true,
          content: llm_reply.content,
          usage:   llm_reply.usage
        }
        payload[:warning] = 'guard skipped: llm unavailable' if llm_unavailable
        payload
      end
    end
  end
end
