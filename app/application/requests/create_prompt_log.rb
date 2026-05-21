# frozen_string_literal: true

require 'dry-validation'
require 'time'

module Tyla
  module Request
    # Accepts the prompt-log shape posted by the CLI guard:
    #   { course_id, project_id, student_id, timestamp,
    #     userPrompt, attack_probability, evaluation }
    #
    # NOTE: the wire format uses `attack-probability` (hyphen). The hyphen is
    # normalised to the underscore key `attack_probability` before this
    # contract runs (see controllers layer / request param coercion).
    class CreatePromptLog < Dry::Validation::Contract
      params do
        required(:course_id).filled(:string)
        required(:project_id).filled(:string)
        required(:student_id).filled(:string)
        required(:timestamp).filled(:string)
        required(:userPrompt).filled(:string)
        required(:attack_probability).filled(:float)
        required(:evaluation).filled(:string)
      end

      rule(:timestamp) do
        Time.iso8601(value)
      rescue ArgumentError
        key.failure('must be an ISO8601 timestamp')
      end

      # Map the external API shape onto the domain Entity::PromptLog
      # vocabulary. External API names must not leak past this method.
      def self.to_entity(validated_hash)
        Entity::PromptLog.new(
          id:                 nil,
          course_id:          validated_hash[:course_id],
          project_id:         validated_hash[:project_id],
          student_id:         validated_hash[:student_id],
          prompt:             validated_hash[:userPrompt],
          attack_probability: validated_hash[:attack_probability],
          evaluation:         validated_hash[:evaluation],
          created_at:         Time.iso8601(validated_hash[:timestamp])
        )
      end
    end
  end
end
