# frozen_string_literal: true

module Tyla
  module Prompts
    # Budget-aware variant that owns *all* LLM-input trimming for /tutor_chats.
    # The pipeline is:
    #
    #   1. mandatory: persona + assignment + user prompt + overhead — plus the
    #      solution ONLY when `include_solution:` is set (hybrid lazy, plan
    #      2026-06-11): round 1 withholds it; round 2 injects it as mandatory
    #      (the model explicitly asked), squeezing droppables, never itself.
    #      Round-2 base equals the old always-eager base, so no new 413 path.
    #   2. droppable: `workspace_overview` (plan 2026-06-12) — the cheap file
    #      listing budgeted FIRST (before file_context, before history): it is
    #      the manifest that makes `load_file` usable, so it earns the budget
    #      ahead of loaded contents.
    #   3. droppable: workspace block (whole, never per-line) — either the live
    #      `file_context` when supplied, otherwise the fixture student file
    #      (the fixture is the Phase-1 fallback used ONLY when the frontend sent
    #      neither overview nor file_context)
    #   4. droppable: chat history (newest-first walk; stop at first turn that
    #      does not fit — no skip-past-large-turn, no mid-turn split)
    #
    # `workspace_overview` and `file_context` coexist: the overview lists every
    # workspace file, `file_context` carries the loaded subset. Each droppable is
    # budgeted whole (never per-line), in the order above, so a dropped block
    # frees its budget back to the slots below it.
    #
    # If even (1) exceeds the channel's input budget, returns a Result with
    # `overflow? == true`; the caller maps that to HTTP 413.
    module BudgetAwarePromptAssembler
      FORMATTING_OVERHEAD = 200
      ROLE_OVERHEAD       = 4

      Result = Struct.new(
        :system_prompt, :history, :max_tokens,
        :student_file_dropped, :workspace_overview_dropped, :history_turns_dropped, :overflow?,
        keyword_init: true
      )

      def self.call(persona:, assignment:, solution:, student_file:, history:,
                    user_prompt:, endpoint:, file_context: nil, workspace_overview: nil,
                    include_solution: false)
        budget = Values::TokenBudget.for(endpoint: endpoint)

        base_tokens =
          Values::Tokenizer.estimate(persona) +
          Values::Tokenizer.estimate(assignment) +
          (include_solution ? Values::Tokenizer.estimate(solution) : 0) +
          Values::Tokenizer.estimate(user_prompt) +
          FORMATTING_OVERHEAD

        if base_tokens > budget.input_token_limit
          return Result.new(
            system_prompt:              nil,
            history:                    [],
            max_tokens:                 budget.output_reservation,
            student_file_dropped:       true,
            workspace_overview_dropped: false,
            history_turns_dropped:      Array(history).size,
            overflow?:                  true
          )
        end

        remaining = budget.input_token_limit - base_tokens

        included_files    = []
        live_context      = nil
        overview          = nil
        workspace_dropped = false
        overview_dropped  = false

        # 1. workspace_overview — the cheap manifest, budgeted first.
        unless workspace_overview.nil? || workspace_overview.empty?
          ov_tokens = Values::Tokenizer.estimate(workspace_overview)
          if ov_tokens <= remaining
            overview   = workspace_overview
            remaining -= ov_tokens
          else
            overview_dropped = true   # dropped whole; freed budget flows to file_context/history
          end
        end

        # 2. file_context (loaded contents), or — only when the frontend sent NO
        #    workspace info at all — the Phase-1 fixture student file.
        if !file_context.nil? && !file_context.empty?
          fc_tokens = Values::Tokenizer.estimate(file_context)
          if fc_tokens <= remaining
            live_context = file_context
            remaining   -= fc_tokens
          else
            workspace_dropped = true   # dropped whole; freed budget flows to history
          end
        elsif workspace_overview.nil? || workspace_overview.empty?
          student_content = student_file && (student_file[:content] || student_file['content'])
          student_path    = student_file && (student_file[:path]    || student_file['path'])

          unless student_content.nil? || student_content.empty?
            file_tokens = Values::Tokenizer.estimate(student_content)
            if file_tokens <= remaining
              included_files = [{ path: student_path, content: student_content }]
              remaining     -= file_tokens
            else
              workspace_dropped = true
            end
          end
        end

        selected, dropped = trim_history(history, remaining)

        system_prompt = TutorSystemPrompt.build(
          policy_text:        persona,
          assignment_text:    assignment,
          solution_text:      include_solution ? solution : nil,
          context_files:      included_files,
          live_context:       live_context,
          workspace_overview: overview
        )

        Result.new(
          system_prompt:              system_prompt,
          history:                    selected,
          max_tokens:                 budget.output_reservation,
          student_file_dropped:       workspace_dropped,
          workspace_overview_dropped: overview_dropped,
          history_turns_dropped:      dropped,
          overflow?:                  false
        )
      end

      def self.trim_history(history, remaining)
        turns = Array(history)
        return [[], 0] if turns.empty?

        selected = []
        kept     = 0
        turns.reverse_each do |turn|
          content = turn[:content] || turn['content']
          cost    = Values::Tokenizer.estimate(content) + ROLE_OVERHEAD
          break if cost > remaining

          selected.unshift(turn)
          remaining -= cost
          kept      += 1
        end

        [selected, turns.size - kept]
      end
      private_class_method :trim_history
    end
  end
end
