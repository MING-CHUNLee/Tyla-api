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
      attribute :attack_probability, Types::Strict::Float.optional
      attribute :evaluation,         Types::String.optional
      attribute :created_at,         Types::Nominal::Time.optional

      def to_attr_hash
        to_hash.except(:id).compact
      end
    end
  end
end
