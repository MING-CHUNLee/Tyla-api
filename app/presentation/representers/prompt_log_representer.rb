# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

module Tyla
  module Representer
    class PromptLog < Roar::Decorator
      include Roar::JSON

      property :id
      property :course_id
      property :project_id
      property :student_id
      property :prompt
      property :attack_probability
      property :evaluation
      property :created_at,
               getter: ->(_) { created_at&.iso8601 }
    end
  end
end
