# frozen_string_literal: true

module Tyla
  module Services
    class GuardAgent
      def initialize(llm_client:)
        @llm = llm_client
      end

      # Returns Values::GuardResult.
      # Fail-open when judge is unavailable; hard-block when attack >= THRESHOLD.
      def check(prompt:, mode:)
        response = @llm.send_prompt(
          system_prompt: Prompts::JudgeSystemPrompt.build,
          user_message:  prompt
        )

        begin
          parsed      = JSON.parse(response.content)
          attack_prob = Float(parsed.fetch('attack-probability'))
          evaluation  = parsed.fetch('evaluation')

          Values::GuardResult.new(
            reason:      evaluation,
            probability: { attack: attack_prob },
            usage:       response.usage
          )
        rescue StandardError => e
          warn "[GuardAgent] judge reply unparseable (#{e.class}): #{e.message}"
          Values::GuardResult.new(
            allowed: true,
            reason:  "llm-judge unavailable: #{e.class}",
            usage:   response.usage
          )
        end
      rescue StandardError => e
        warn "[GuardAgent] judge unavailable (#{e.class}): #{e.message}"
        Values::GuardResult.new(allowed: true, reason: "llm-judge unavailable: #{e.class}")
      end
    end
  end
end
