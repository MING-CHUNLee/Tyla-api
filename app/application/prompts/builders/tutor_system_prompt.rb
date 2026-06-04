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
      # Decision rules for when to call each tool. Format instructions are
      # handled by the tool_use API — not needed in the prompt.
      TOOL_USE_GUIDE = <<~GUIDE.strip
        ## Tool Use Guide
        Call `edit_file` when the exact code to fix is visible in the student workspace — apply the fix directly without asking first.
        Call `execute_script` when the student asks for a demo, example, or step-by-step illustration — provide the R code directly without asking for confirmation first.
        Call `load_file` when you need to see a workspace file not provided in context.
        Do NOT offer to run code as a follow-up question ("Would you like me to..."). If code would help, call the tool immediately.
        If you have no concrete code to act on, or when refusing, do not call any tool.
      GUIDE

      def self.build(policy_text:, solution_text:, context_files:, live_context: nil)
        parts = [policy_text]
        parts << "## Reference Solution\n#{solution_text}" unless blank?(solution_text)

        if !blank?(live_context)
          parts << "## Student Workspace (live)\n#{live_context}"
        elsif !blank?(context_files)
          file_block = context_files.map { |f| format_file(f) }.join("\n\n")
          parts << "## Student Workspace Files\n#{file_block}"
        end

        parts << TOOL_USE_GUIDE
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
