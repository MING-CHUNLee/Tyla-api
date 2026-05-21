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
        response    = @llm.send_prompt(
          system_prompt: Prompts::JudgeSystemPrompt.build,
          user_message:  prompt
        )
        parsed      = JSON.parse(response.content)
        attack_prob = Float(parsed.fetch('attack-probability'))
        evaluation  = parsed.fetch('evaluation')
        benign_prob = (1.0 - attack_prob).round(4)
        allowed     = attack_prob < Values::AttackPolicy::THRESHOLD

        Values::GuardResult.new(
          allowed:     allowed,
          reason:      evaluation,
          probability: { attack: attack_prob, benign: benign_prob }
        )
      rescue StandardError => e
        warn "[GuardAgent] judge unavailable (#{e.class}): #{e.message}"
        Values::GuardResult.new(allowed: true, reason: "llm-judge unavailable: #{e.class}")
      end
    end
  end
end
