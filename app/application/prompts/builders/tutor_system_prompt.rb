# frozen_string_literal: true

module Tyla
  module Prompts
    # Pure composer: glues policy + assignment + course-materials manifest +
    # (optional) solution + workspace blocks into one system prompt string.
    # Trimming (history truncation, workspace drop) is the assembler's job,
    # not this builder's.
    #
    # Hybrid lazy solution (plan 2026-06-11): the assignment always renders;
    # the solution renders only when `solution_text` is given (round 2). The
    # manifest always renders and switches wording once the solution is in,
    # so the model neither re-requests it nor mentions "looking it up".
    # The manifest lists COURSE MATERIALS only — student workspace files are
    # the frontend's manifest (`file_context` / B3), not this builder's (S1).
    #
    # Workspace rendering: when `live_context` (the request's `file_context`)
    # is present it renders under `## Student Workspace (live)` and SUPPRESSES
    # the fixture `## Student Workspace Files` block (Q-B1). When absent, the
    # fixture `context_files` render as before. Exactly one section appears.
    module TutorSystemPrompt
      # Always rendered (eager) right after the assignment: tells the model the
      # solution exists and how to get it, without paying its tokens up front.
      COURSE_MATERIALS_MANIFEST = <<~MANIFEST.strip
        ## Available Course Materials
        - `reference_solution` — instructor's reference solution for this assignment.
          Not loaded by default. Call `load_reference` to consult it BEFORE advising on
          how to structure, improve, or verify the student's work.
      MANIFEST

      # Round-2 replacement: marks the material as satisfied so the model does
      # not tell the student it is "going to consult the answer key".
      MANIFEST_SOLUTION_LOADED = <<~MANIFEST.strip
        ## Available Course Materials
        - `reference_solution` is included below under "## Reference Solution".
          Do not mention loading or consulting reference materials to the student.
      MANIFEST

      # Decision rules for when to call each tool. Format instructions are
      # handled by the tool_use API — not needed in the prompt.
      TOOL_USE_GUIDE = <<~GUIDE.strip
        ## Tool Use Guide
        Call `edit_file` when the exact code to fix is visible in the student workspace — apply the fix directly without asking first.
        Call `execute_script` when the student asks for a demo, example, or step-by-step illustration — provide the R code directly without asking for confirmation first.
        Call `load_file` when you need to see a workspace file not provided in context.
        Call `load_reference` when the question concerns how to approach, structure, improve, or check the homework. Do NOT call it for purely logistical questions (deadlines, submission format).
        Do NOT offer to run code as a follow-up question ("Would you like me to..."). If code would help, call the tool immediately.
        If you have no concrete code to act on, or when refusing, do not call any tool.
      GUIDE

      # Line-number contract for live workspace files (plan 2026-06-11 §2.1/§2.2).
      # Appended ONLY on the live_context branch — fixture context_files carry no
      # line numbers, so adding it unconditionally would teach the model wrong.
      LINE_NUMBER_GUIDE = <<~GUIDE.strip
        ## Workspace Line Numbers
        Every line in the live workspace files is prefixed with its line number ("12| ").
        - In edit_file `search`, copy the lines verbatim INCLUDING the number prefixes.
        - In edit_file `replace`, write plain code WITHOUT number prefixes.
        - When quoting code in your explanation to the student, omit the prefixes.
      GUIDE

      def self.build(policy_text:, solution_text:, context_files:, live_context: nil, assignment_text: nil)
        parts = [policy_text]
        parts << "## Assignment\n#{assignment_text}" unless blank?(assignment_text)
        parts << (blank?(solution_text) ? COURSE_MATERIALS_MANIFEST : MANIFEST_SOLUTION_LOADED)
        parts << "## Reference Solution\n#{solution_text}" unless blank?(solution_text)

        if !blank?(live_context)
          parts << "## Student Workspace (live)\n#{live_context}"
          parts << LINE_NUMBER_GUIDE
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
