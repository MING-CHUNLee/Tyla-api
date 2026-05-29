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
        return Failure[:forbidden, 'missing X-LLM-Key'] if api_key.nil? || api_key.empty?

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
          return Success([:forbidden, build_forbidden_response(log.id, params[:project_id], guard_result.usage)])
        end

        assembled = Prompts::BudgetAwarePromptAssembler.call(
          persona:      Infrastructure::Filesystem::TutorPersonaLoader.load(params[:project_id]),
          assignment:   Infrastructure::Filesystem::AssignmentLoader.load(params[:project_id]),
          solution:     Infrastructure::Filesystem::SolutionLoader.load(params[:project_id]),
          student_file: { path:    Infrastructure::Filesystem::StudentFileLoader::FILENAME,
                          content: Infrastructure::Filesystem::StudentFileLoader.load(params[:project_id]) },
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

        response = build_ok_response(log.id, llm_reply, guard_result, llm_unavailable: llm_unavailable)
        Success([llm_unavailable ? :unavailable : :done, response])
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

      def build_forbidden_response(log_id, project_id, guard_usage)
        Response::TutorChat.new(
          log_id:  log_id,
          status:  'forbidden',
          content: Infrastructure::Filesystem::RefusalLoader.load(project_id),
          usage:   guard_usage
        )
      end

      def build_ok_response(log_id, llm_reply, guard_result, llm_unavailable:)
        Response::TutorChat.new(
          log_id:  log_id,
          status:  llm_unavailable ? 'unavailable' : 'done',
          content: llm_reply.content,
          usage:   usage_sum(guard_result.usage, llm_reply.usage)
        )
      end

      def usage_sum(a, b)
        a ||= {}
        b ||= {}
        {
          input_tokens:  (a[:input_tokens]  || 0) + (b[:input_tokens]  || 0),
          output_tokens: (a[:output_tokens] || 0) + (b[:output_tokens] || 0)
        }
      end
    end
  end
end
