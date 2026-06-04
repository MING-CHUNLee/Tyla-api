# frozen_string_literal: true

module Tyla
  module Prompts
    # Pure composer: glues policy + solution + workspace blocks into one
    # system prompt string. Trimming (history truncation, workspace drop)
    # is the assembler's job, not this builder's.
    #
    # Workspace rendering: when `live_context` (the request's `file_context`)
    # is present it renders under `## Student Workspace (live)` and SUPPRESSES
    # the fixture `## Student Workspace Files` block (Q-B1). When absent, the
    # fixture `context_files` render as before. Exactly one section appears.
    module TutorSystemPrompt
      # Static wire-format instructions for the structured actions array. The
      # tutor appends a single <actions>[...]</actions> JSON block after its
      # prose; Values::TutorReplyParser parses it back out.
      ACTIONS_PROTOCOL = <<~PROTOCOL.strip
        ## Actions Protocol
        When you have a concrete, ready-to-apply code suggestion, after your prose emit a
        single `<actions>[...]</actions>` block containing a JSON array of action objects.
        Each object is one of:
        - `{ "type": "edit_file", "path": "<file>", "patches": [ { "search": "<exact snippet>", "replace": "<new snippet>" } ] }` — use search/replace patches, never full file contents; make each `search` string unique enough to be unambiguous.
        - `{ "type": "execute_script", "code": "<R code>" }` — read-only, no file writes or installs.
        - `{ "type": "load_file", "path": "<file>" }`
        Omit the `<actions>` block entirely when you have no concrete suggestion. Never emit it when refusing.
      PROTOCOL

      def self.build(policy_text:, solution_text:, context_files:, live_context: nil)
        parts = [policy_text]
        parts << "## Reference Solution\n#{solution_text}" unless blank?(solution_text)

        if !blank?(live_context)
          parts << "## Student Workspace (live)\n#{live_context}"   # NEW — suppresses fixture WIP
        elsif !blank?(context_files)
          file_block = context_files.map { |f| format_file(f) }.join("\n\n")
          parts << "## Student Workspace Files\n#{file_block}"
        end

        parts << ACTIONS_PROTOCOL                                   # NEW — static instructions
        parts.join("\n\n---\n\n")
      end

      def self.blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
      private_class_method :blank?

      def self.format_file(file)
        path    = file[:path]    || file['path']
        content = file[:content] || file['content'] || ''
        "### #{path}\n```\n#{content}\n```"
      end
      private_class_method :format_file
    end
  end
end
