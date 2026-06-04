# frozen_string_literal: true

require 'json'

module Tyla
  module Values
    # Splits a tutor LLM reply into prose and a structured actions array.
    # The tutor is instructed (TutorSystemPrompt::ACTIONS_PROTOCOL) to append a
    # single `<actions>[...]</actions>` JSON block after its prose when it has a
    # concrete suggestion. Parsing is permissive: malformed or non-array JSON is
    # dropped (actions => []) while the prose is always kept (Q-B2). Per-action
    # schema validation is the frontend's concern (Q3).
    module TutorReplyParser
      BLOCK = %r{<actions>\s*(.*?)\s*</actions>}m

      # Returns [prose, actions]. actions is always an Array ([] when none/malformed).
      def self.call(content)
        text = content.to_s
        m    = text.match(BLOCK)
        return [text.strip, []] unless m

        prose   = text.sub(BLOCK, '').strip
        actions = parse(m[1])
        [prose, actions]
      end

      def self.parse(json)
        parsed = JSON.parse(json)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        [] # malformed → drop actions, keep prose (Q-B2)
      end
      private_class_method :parse
    end
  end
end
