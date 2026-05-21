# frozen_string_literal: true

module Tyla
  module Services
    class TutorChatResult
      attr_reader :status, :content, :reason, :probability, :usage

      def initialize(status:, content:, reason: nil, probability: nil, usage: nil)
        @status      = status
        @content     = content
        @reason      = reason
        @probability = probability
        @usage       = usage
      end

      def self.ok(content:, usage:, guard:)
        new(status: 'ok', content: content, usage: usage)
      end

      def self.refused(content:, reason:, probability:)
        new(status: 'refused', content: content, reason: reason, probability: probability)
      end

      def allowed?
        @status == 'ok'
      end
    end
  end
end
