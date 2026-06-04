# frozen_string_literal: true

require 'dry-validation'
require 'json'

module Tyla
  module Request
    class TutorChat < Dry::Validation::Contract
      MAX_HISTORY_BYTES = 500_000

      params do
        required(:course_id).filled(:string)
        required(:project_id).filled(:string)
        required(:student_id).filled(:string)
        required(:guard_log_id).filled(:integer)   # NEW — missing/wrong-type → bad_request (400)
        required(:prompt).filled(:string)
        optional(:history).array(:hash) do
          required(:role).filled(:string)
          required(:content).filled(:string)
        end
        optional(:file_context).filled(:string)    # NEW — optional live-workspace block
      end

      rule(:history) do
        next unless value

        bytes = value.to_json.bytesize
        key.failure("exceeds #{MAX_HISTORY_BYTES} bytes") if bytes > MAX_HISTORY_BYTES
      end
    end
  end
end
