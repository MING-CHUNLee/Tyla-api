# frozen_string_literal: true

require 'set'

module Tyla
  module Values
    # Single source of truth for the `### <relative path>` header that marks a
    # file section inside file_context. Consumers: WorkspaceEditGate,
    # RedundantLoadGate, EditPatchContentGate, HistoryTurnSerializer.
    # Producer: TutorSystemPrompt (via `.line`).
    #
    # CRLF note: HEADER alone is not CRLF-complete — on a CRLF line the capture
    # group keeps a trailing "\r" (Ruby `.` matches `\r`, `$` anchors only before
    # `\n`). `.normalize` strips it. Always read paths via `.paths` or
    # `.normalize`, never the raw capture group.
    module FileContextHeader
      HEADER = /^###[ \t]+(\S.*?)[ \t]*$/

      def self.paths(file_context)
        file_context.to_s.lines.each_with_object(Set.new) do |line, set|
          m = line.match(HEADER)
          set << normalize(m[1]) if m
        end
      end

      def self.normalize(path)
        path.to_s.strip.tr('\\', '/').sub(%r{\A\./}, '')
      end

      def self.line(path) = "### #{path}"
    end
  end
end
