# frozen_string_literal: true

module Tyla
  module Middleware
    class KeyScrubber
      KEY_PATTERN = /(?:X-LLM-Key\s*:\s*|Bearer\s+)?(sk-[A-Za-z0-9_\-]+)/i
      REPLACEMENT = '[REDACTED]'

      def initialize(app)
        @app = app
      end

      def call(env)
        status, headers, body = @app.call(env)
        scrubbed = []
        body.each { |chunk| scrubbed << scrub(chunk) }
        body.close if body.respond_to?(:close)
        [status, headers, scrubbed]
      end

      private

      def scrub(chunk)
        return chunk unless chunk.is_a?(String)

        chunk.gsub(KEY_PATTERN) do |match|
          # Preserve the X-LLM-Key:/Bearer prefix if present, redact only the key.
          if match.start_with?(/sk-/i)
            REPLACEMENT
          else
            prefix = match[0...(match.index(/sk-/i))]
            "#{prefix}#{REPLACEMENT}"
          end
        end
      end
    end
  end
end
