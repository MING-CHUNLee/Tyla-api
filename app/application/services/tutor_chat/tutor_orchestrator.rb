# frozen_string_literal: true

require 'dry/monads'

module Tyla
  module Services
    class TutorOrchestrator
      include Dry::Monads[:result]

      def initialize(llm_client:, guard:, policy_loader:)
        @llm    = llm_client
        @guard  = guard
        @policy = policy_loader
      end

      def call(request)
        policy_text  = @policy.load(request.mode)
        guard_result = @guard.check(prompt: request.user_prompt, mode: request.mode)

        if guard_result.allowed?
          composed = Prompts::TutorSystemPrompt.build(
            policy_text:   policy_text,
            solution_text: Infrastructure::Filesystem::SolutionLoader.load_stub,
            context_files: request.context_files
          )
          truncated_history = Prompts::TutorSystemPrompt.truncate_history(request.history)
          llm_response = @llm.send_prompt(
            system_prompt: composed,
            user_message:  request.user_prompt,
            history:       truncated_history
          )
          Success(TutorChatResult.ok(content: llm_response.content, usage: llm_response.usage, guard: guard_result))
        else
          Success(TutorChatResult.refused(
            content:     Values::RefusalTemplates.for(request.mode),
            reason:      guard_result.reason,
            probability: guard_result.probability
          ))
        end
      rescue ArgumentError => e
        Failure[:bad_mode, e.message]
      rescue Infrastructure::LlmError::Timeout
        Failure[:upstream_timeout, 'LLM request timed out']
      rescue Infrastructure::LlmError::Upstream => e
        Failure[:upstream_error, e.message]
      end
    end
  end
end
