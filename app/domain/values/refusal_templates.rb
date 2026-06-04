# frozen_string_literal: true

module Tyla
  module Values
    module RefusalTemplates
      TEMPLATES = [
        "That question isn't something I can help with directly here. " \
        'What aspect of the topic are you trying to understand?',
        "I'm not able to respond to that. " \
        "Try rephrasing as a conceptual question — what's the first idea you'd explore?",
        "Let's work through this together. What aspect of the problem would you like to explore first?"
      ].freeze

      def self.for(_mode = nil)
        TEMPLATES.sample
      end
    end
  end
end
