# frozen_string_literal: true

require 'dry-validation'

module Tyla
  module Request
    class GuardCheck < Dry::Validation::Contract
      params do
        required(:course_id).filled(:string)
        required(:project_id).filled(:string)
        required(:student_id).filled(:string)
        required(:prompt).filled(:string)
      end
    end
  end
end
