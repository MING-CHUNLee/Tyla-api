# frozen_string_literal: true

module Tyla
  module Values
    module RefusalTemplates
      TEMPLATES = [
        "That question isn't something I can help with directly here. " \
        'What aspect of the topic are you trying to understand?',
        "I'm not able to respond to that. " \
        "Try rephrasing as a conceptual question — what's the first idea you'd explore?",
        "Let's redirect. Instead of asking for the answer, what step would you take first to approach this problem?"
      ].freeze

      def self.for(_mode = nil)
        TEMPLATES.sample
      end
    end
  end
end
