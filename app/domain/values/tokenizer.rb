# frozen_string_literal: true

module Tyla
  module Values
    # Pre-call token estimation. Heuristic — `chars / CHARS_PER_TOKEN` — chosen
    # deliberately over `tiktoken_ruby` for v1 (zero native deps, deterministic
    # in tests). Calibrate against `usage.input_tokens` post-deploy and revisit
    # the constant if drift is observed.
    module Tokenizer
      CHARS_PER_TOKEN = 3.5

      def self.estimate(text)
        return 0 if text.nil? || text.empty?

        (text.length / CHARS_PER_TOKEN).ceil
      end
    end
  end
end
