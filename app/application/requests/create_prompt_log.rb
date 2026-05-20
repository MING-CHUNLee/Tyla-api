# frozen_string_literal: true

require 'dry-validation'

module Tyla
  module Request
    # Accepts the log shape emitted by the CLI guard:
    #   { course_id, project_id, student_id,
    #     userPrompt, probability: { attack, benign },
    #     reason, allowed, timestamp }
    class CreatePromptLog < Dry::Validation::Contract
      params do
        required(:course_id).filled(:string)
        required(:project_id).filled(:string)
        required(:student_id).filled(:string)
        required(:userPrompt).filled(:string)
        required(:probability).hash do
          required(:attack).filled(:float)
          required(:benign).filled(:float)
        end
        optional(:reason).maybe(:string)
        optional(:allowed).maybe(:bool)
        optional(:timestamp).maybe(:string)
      end

      # Map the external API shape (`userPrompt`, `probability[:attack]`)
      # onto the domain Entity::PromptLog vocabulary. External API names
      # must not leak past this method.
      def self.to_entity(validated_hash)
        Entity::PromptLog.new(
          id:          nil,
          course_id:   validated_hash[:course_id],
          project_id:  validated_hash[:project_id],
          student_id:  validated_hash[:student_id],
          prompt:      validated_hash[:userPrompt],
          attack_prob: validated_hash[:probability][:attack],
          benign_prob: validated_hash[:probability][:benign],
          reason:      validated_hash[:reason],
          allowed:     validated_hash.fetch(:allowed, true),
          created_at:  nil
        )
      end
    end
  end
end
