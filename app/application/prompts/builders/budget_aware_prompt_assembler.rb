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
    #   2. droppable: workspace block (whole, never per-line) — either the live
    #      `file_context` when supplied, otherwise the fixture student file
    #   3. droppable: chat history (newest-first walk; stop at first turn that
    #      does not fit — no skip-past-large-turn, no mid-turn split)
    #
    # When `file_context` is present it occupies the workspace slot and the
    # fixture student file is suppressed (Q-B1); it is budgeted in the same slot
    # (before history) so a dropped block frees its budget back to history.
    #
    # If even (1) exceeds the channel's input budget, returns a Result with
    # `overflow? == true`; the caller maps that to HTTP 413.
    module BudgetAwarePromptAssembler
      FORMATTING_OVERHEAD = 200
      ROLE_OVERHEAD       = 4

      Result = Struct.new(
        :system_prompt, :history, :max_tokens,
        :student_file_dropped, :history_turns_dropped, :overflow?,
        keyword_init: true
      )

      def self.call(persona:, assignment:, solution:, student_file:, history:,
                    user_prompt:, endpoint:, file_context: nil, include_solution: false)
        budget = Values::TokenBudget.for(endpoint: endpoint)

        base_tokens =
          Values::Tokenizer.estimate(persona) +
          Values::Tokenizer.estimate(assignment) +
          (include_solution ? Values::Tokenizer.estimate(solution) : 0) +
          Values::Tokenizer.estimate(user_prompt) +
          FORMATTING_OVERHEAD

        if base_tokens > budget.input_token_limit
          return Result.new(
            system_prompt:         nil,
            history:               [],
            max_tokens:            budget.output_reservation,
            student_file_dropped:  true,
            history_turns_dropped: Array(history).size,
            overflow?:             true
          )
        end

        remaining = budget.input_token_limit - base_tokens

        included_files = []
        live_context   = nil
        workspace_dropped = false

        if !file_context.nil? && !file_context.empty?
          # Live workspace path — fixture student file is suppressed (Q-B1).
          fc_tokens = Values::Tokenizer.estimate(file_context)
          if fc_tokens <= remaining
            live_context = file_context
            remaining   -= fc_tokens
          else
            workspace_dropped = true   # dropped whole; freed budget flows to history
          end
        else
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
          policy_text:     persona,
          assignment_text: assignment,
          solution_text:   include_solution ? solution : nil,
          context_files:   included_files,
          live_context:    live_context
        )

        Result.new(
          system_prompt:         system_prompt,
          history:               selected,
          max_tokens:            budget.output_reservation,
          student_file_dropped:  workspace_dropped,
          history_turns_dropped: dropped,
          overflow?:             false
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
