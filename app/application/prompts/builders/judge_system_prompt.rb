# frozen_string_literal: true

module Tyla
  module Prompts
    module JudgeSystemPrompt
      TEMPLATE_PATH = File.expand_path('../guard-judge.md', __dir__)
      CATALOG_PATH  = File.expand_path('../jailbreak-strategies.md', __dir__)

      def self.build
        template = File.read(TEMPLATE_PATH)
        catalog  = File.read(CATALOG_PATH)
        template.gsub('{{jailbreakCatalog}}', catalog)
      end
    end
  end
end
