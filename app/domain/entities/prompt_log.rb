# frozen_string_literal: true

require 'dry-struct'
require 'dry-types'

module Tyla
  module Entity
    class PromptLog < Dry::Struct
      module Types
        include Dry.Types()
      end

      attribute :id,                 Types::Integer.optional
      attribute :course_id,          Types::Strict::String
      attribute :project_id,         Types::Strict::String
      attribute :student_id,         Types::Strict::String
      attribute :prompt,             Types::Strict::String
      # The pending-row workflow (see HandleTutorChat) writes the row with
      # attack_probability and evaluation as nil before the LLM is called,
      # then back-fills them after the orchestrator returns. These attributes
      # are therefore optional even though the route's CreatePromptLog
      # contract always supplies them.
      attribute :attack_probability, Types::Strict::Float.optional
      attribute :evaluation,         Types::String.optional
      attribute :created_at,         Types::Nominal::Time.optional

      def to_attr_hash
        to_hash.except(:id).compact
      end
    end
  end
end
