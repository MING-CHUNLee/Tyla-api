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
    end
  end
end
