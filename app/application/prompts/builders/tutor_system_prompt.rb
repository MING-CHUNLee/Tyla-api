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
    # Workspace rendering (plan 2026-06-12 — two-channel contract):
    # `workspace_overview` is the frontend's file LISTING (no contents, no line
    # numbers) and renders under `## Student Workspace (overview)`; `live_context`
    # (the request's `file_context`) is the line-numbered contents of files the
    # frontend has actually loaded and renders under `## Student Workspace (live)`.
    # The two coexist. The fixture `## Student Workspace Files` block is a Phase-1
    # fallback rendered ONLY when the frontend supplied neither field.
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
        Call `edit_file` ONLY when the target file is shown in the "Student Workspace (live)" section with real "N| " line numbers — set `start_line` to the line number shown and put plain code (no "N| " prefix) in `search`, and apply the fix directly without asking first. If the file appears only in the "Student Workspace (overview)" section, is not shown at all, or the student merely pasted code into the chat, call `load_file` FIRST and wait for its numbered contents — never guess line numbers or invent a "N| " prefix.
        Call `execute_script` when the student asks for a demo, example, or step-by-step illustration — provide the R code directly without asking for confirmation first.
        Call `load_file` when you need a workspace file that is not yet in the "Student Workspace (live)" section (listed only in the overview, or not shown). Its contents arrive next turn; do not edit it before then.
        Call `load_reference` when the question concerns how to approach, structure, improve, or check the homework. Do NOT call it for purely logistical questions (deadlines, submission format).
        Do NOT offer to run code as a follow-up question ("Would you like me to..."). If code would help, call the tool immediately.
        If you have no concrete code to act on, or when refusing, do not call any tool.
      GUIDE

      # Appended ONLY on the `workspace_overview` branch (plan 2026-06-12 §2).
      # The overview lists files whose contents are NOT loaded, so it must NOT
      # carry the line-number promise — instead it steers the model to load_file.
      WORKSPACE_OVERVIEW_GUIDE = <<~GUIDE.strip
        ## Loading Workspace Files
        The files listed above exist in the student's workspace but their contents are NOT loaded.
        - To read or edit any of them, call `load_file` with its path FIRST; the numbered contents arrive next turn in the "Student Workspace (live)" section.
        - Only files shown in the "Student Workspace (live)" section carry real line numbers. Never invent or guess a "N| " line-number prefix for a file that is not loaded — not even if the student pasted some of its lines into the chat.
        - Do NOT emit `edit_file` for a file that is not in the "Student Workspace (live)" section; `load_file` it first.
      GUIDE

      # Line-number contract for live workspace files (plan 2026-06-11 §2.1/§2.2).
      # Appended ONLY on the live_context branch — fixture context_files carry no
      # line numbers, so adding it unconditionally would teach the model wrong.
      LINE_NUMBER_GUIDE = <<~GUIDE.strip
        ## Workspace Line Numbers
        Every line in the live workspace files is prefixed with its line number ("12| ").
        - In edit_file, set `start_line` to the number shown on the first line you are replacing.
        - Put plain code (NO "N| " prefixes) in both `search` and `replace`.
        - When quoting code in your explanation to the student, omit the prefixes.
      GUIDE

      def self.build(policy_text:, solution_text:, context_files:, live_context: nil,
                     workspace_overview: nil, assignment_text: nil)
        parts = [policy_text]
        parts << "## Assignment\n#{assignment_text}" unless blank?(assignment_text)
        parts << (blank?(solution_text) ? COURSE_MATERIALS_MANIFEST : MANIFEST_SOLUTION_LOADED)
        parts << "## Reference Solution\n#{solution_text}" unless blank?(solution_text)
        parts.concat(workspace_parts(live_context, workspace_overview, context_files))
        parts << TOOL_USE_GUIDE
        parts.join("\n\n---\n\n")
      end

      # The overview (manifest) and the live (loaded contents) sections coexist;
      # the fixture block is a Phase-1 fallback rendered only when the frontend
      # sent neither. Each carries its own guide — no line-number guide on the
      # overview, which has no numbered lines.
      def self.workspace_parts(live_context, workspace_overview, context_files)
        parts = []
        unless blank?(workspace_overview)
          parts << "## Student Workspace (overview)\n#{workspace_overview}" << WORKSPACE_OVERVIEW_GUIDE
        end
        if !blank?(live_context)
          parts << "## Student Workspace (live)\n#{live_context}" << LINE_NUMBER_GUIDE
        elsif blank?(workspace_overview) && !blank?(context_files)
          parts << "## Student Workspace Files\n#{context_files.map { |f| format_file(f) }.join("\n\n")}"
        end
        parts
      end
      private_class_method :workspace_parts

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
