# frozen_string_literal: true

require_relative '../../../spec_helper'

%w[
  app/domain/values/tokenizer.rb
  app/domain/values/token_budget.rb
  app/application/prompts/builders/tutor_system_prompt.rb
  app/application/prompts/builders/budget_aware_prompt_assembler.rb
].each { |f| require File.join(ROOT, f) }

describe Tyla::Prompts::BudgetAwarePromptAssembler do
  # GitHub Models → 8 000 input, 4 000 output. Used by every test below to
  # keep the numerical reasoning concrete.
  GITHUB_ENDPOINT = 'https://models.inference.ai.azure.com/chat/completions'

  describe 'parent-plan spec (a): budget-aware history trimming' do
    it 'keeps the newest N turns whose total fits the remaining budget and preserves chronological order' do
      # base = persona(0) + assignment(0) + solution(0) + prompt(0) + 200
      #      = 200
      # remaining for history = 8000 - 200 = 7800
      # Each turn: 4200 chars / 3.5 = 1200 tokens + 4 role = 1204
      # 6 × 1204 = 7224 ≤ 7800; 7 × 1204 = 8428 > 7800
      # So exactly the newest 6 of 50 turns should survive.
      history = Array.new(50) do |i|
        { role: i.even? ? 'user' : 'assistant', content: "T#{i}-#{'a' * 4193}" }
      end

      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      '',
        assignment:   '',
        solution:     '',
        student_file: { path: 'x', content: '' },
        history:      history,
        user_prompt:  '',
        endpoint:     GITHUB_ENDPOINT
      )

      _(result.overflow?).must_equal false
      _(result.history.size).must_equal 6
      _(result.history_turns_dropped).must_equal 44
      _(result.history.last).must_equal history.last
      _(result.history).must_equal history.last(6)
    end
  end

  describe 'parent-plan spec (b): whole-file student-file drop' do
    it 'drops the student file when it does not fit and omits its content from the system prompt' do
      # persona = 7000 tokens (24500 chars of recognisable filler)
      # base = 7000 + 0 + 0 + 1 (prompt "hi") + 200 = 7201
      # remaining = 799
      # student_file: 1000 tokens > 799 → dropped
      persona = 'P' * 24_500
      student = "STUDENTFILE_MARKER_#{'x' * 3500}"

      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      persona,
        assignment:   '',
        solution:     '',
        student_file: { path: 'Hw2.Rmd', content: student },
        history:      [],
        user_prompt:  'hi',
        endpoint:     GITHUB_ENDPOINT
      )

      _(result.overflow?).must_equal false
      _(result.student_file_dropped).must_equal true
      _(result.system_prompt).wont_include 'STUDENTFILE_MARKER_'
      _(result.system_prompt).wont_include '### Hw2.Rmd'
    end
  end

  describe 'edge case: turn at position N too large → break (drops N AND everything older)' do
    it 'stops the walk at the first oversized turn; older turns are NOT cherry-picked' do
      # Three turns, newest last. Walk is newest-first.
      #   - newest 'recent' fits
      #   - second-newest 'HUGE' does not fit → break
      #   - oldest 'small' would fit if continued — but break means it is dropped.
      # Must exceed `remaining` *after* the newest turn has been kept. With an
      # 8 K budget, 200 overhead, and the 'recent-small' turn costing 8 tokens,
      # remaining drops to ~7792 before this turn is examined. 30 000 chars →
      # ~8572 tokens — comfortably over that threshold and over the whole 8 K
      # cap, so it cannot fit even alongside nothing else.
      huge_content = 'H' * 30_000
      history = [
        { role: 'user',      content: 'old-small' },
        { role: 'assistant', content: huge_content },
        { role: 'user',      content: 'recent-small' }
      ]

      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      '',
        assignment:   '',
        solution:     '',
        student_file: { path: 'x', content: '' },
        history:      history,
        user_prompt:  '',
        endpoint:     GITHUB_ENDPOINT
      )

      _(result.history.size).must_equal 1
      _(result.history.first[:content]).must_equal 'recent-small'
      _(result.history_turns_dropped).must_equal 2
    end
  end

  describe 'edge case: empty / nil inputs' do
    it 'treats nil history as empty without error' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      'P',
        assignment:   'A',
        solution:     'S',
        student_file: { path: 'x', content: 'c' },
        history:      nil,
        user_prompt:  'q',
        endpoint:     GITHUB_ENDPOINT
      )
      _(result.history).must_equal []
      _(result.history_turns_dropped).must_equal 0
    end

    it 'treats empty student_file.content as absent (not dropped)' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      'P',
        assignment:   'A',
        solution:     'S',
        student_file: { path: 'x', content: '' },
        history:      [],
        user_prompt:  'q',
        endpoint:     GITHUB_ENDPOINT
      )
      _(result.student_file_dropped).must_equal false
      _(result.system_prompt).wont_include '### x'
    end
  end

  describe 'edge case: mandatory items overflow' do
    it 'returns overflow? == true when persona+assignment+solution+prompt exceed the budget' do
      # 30_000 chars / 3.5 ≈ 8572 tokens — alone exceeds the 8 K cap.
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      'P' * 30_000,
        assignment:   '',
        solution:     '',
        student_file: { path: 'x', content: 'c' },
        history:      [{ role: 'user', content: 'hi' }],
        user_prompt:  'q',
        endpoint:     GITHUB_ENDPOINT
      )
      _(result.overflow?).must_equal true
      _(result.system_prompt).must_be_nil
      _(result.history).must_equal []
    end
  end

  describe 'channel routing' do
    it 'uses the GitHub Models 4_000 output reservation as max_tokens' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona: 'P', assignment: 'A', solution: 'S',
        student_file: { path: 'x', content: 'c' },
        history: [], user_prompt: 'q',
        endpoint: GITHUB_ENDPOINT
      )
      _(result.max_tokens).must_equal 4_000
    end

    it 'uses the OpenAI-direct 4096 output reservation when the endpoint points at api.openai.com' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona: 'P', assignment: 'A', solution: 'S',
        student_file: { path: 'x', content: 'c' },
        history: [], user_prompt: 'q',
        endpoint: 'https://api.openai.com/v1/chat/completions'
      )
      _(result.max_tokens).must_equal 4_096
    end

    it 'falls back to the :unknown channel for an unrecognised endpoint without raising' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona: 'P', assignment: 'A', solution: 'S',
        student_file: { path: 'x', content: 'c' },
        history: [], user_prompt: 'q',
        endpoint: 'https://example.invalid/api'
      )
      _(result.overflow?).must_equal false
      _(result.max_tokens).must_equal 4_000
    end
  end

  describe 'file_context (live workspace) injection' do
    it 'renders the live block and suppresses the fixture student file when file_context fits' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      '',
        assignment:   '',
        solution:     '',
        student_file: { path: 'Hw2.Rmd', content: 'FIXTURE_STUDENT_FILE_MARKER' },
        history:      [],
        user_prompt:  '',
        endpoint:     GITHUB_ENDPOINT,
        file_context: 'LIVE_FILE_CONTEXT_MARKER'
      )

      _(result.overflow?).must_equal false
      _(result.student_file_dropped).must_equal false
      _(result.system_prompt).must_include '## Student Workspace (live)'
      _(result.system_prompt).must_include 'LIVE_FILE_CONTEXT_MARKER'
      _(result.system_prompt).wont_include '## Student Workspace Files'
      _(result.system_prompt).wont_include 'FIXTURE_STUDENT_FILE_MARKER'
    end

    it 'drops an oversized file_context whole and frees the budget back to history' do
      # 30_000 chars / 3.5 ≈ 8572 tokens — alone exceeds the 8 K cap, so the
      # whole block is dropped. The freed budget then admits the small history turn.
      history = [{ role: 'user', content: 'keep me' }]

      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      '',
        assignment:   '',
        solution:     '',
        student_file: { path: 'x', content: '' },
        history:      history,
        user_prompt:  '',
        endpoint:     GITHUB_ENDPOINT,
        file_context: 'H' * 30_000
      )

      _(result.overflow?).must_equal false
      _(result.student_file_dropped).must_equal true
      _(result.system_prompt).wont_include '## Student Workspace (live)'
      _(result.system_prompt).wont_include 'HHHHHHHHHH'
      _(result.history.size).must_equal 1
      _(result.history_turns_dropped).must_equal 0
    end

    it 'falls back to the fixture student file when file_context is absent' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      '',
        assignment:   '',
        solution:     '',
        student_file: { path: 'Hw2.Rmd', content: 'FIXTURE_STUDENT_FILE_MARKER' },
        history:      [],
        user_prompt:  '',
        endpoint:     GITHUB_ENDPOINT
      )

      _(result.system_prompt).must_include '## Student Workspace Files'
      _(result.system_prompt).must_include 'FIXTURE_STUDENT_FILE_MARKER'
      _(result.system_prompt).wont_include '## Student Workspace (live)'
    end
  end

  describe 'composition' do
    it 'concatenates assignment + reference solution into a single solution_text section' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      'PERSONA_BODY',
        assignment:   'ASSIGNMENT_BODY',
        solution:     'SOLUTION_BODY',
        student_file: { path: 'Hw2.Rmd', content: 'CODE' },
        history:      [],
        user_prompt:  'q',
        endpoint:     GITHUB_ENDPOINT
      )
      _(result.system_prompt).must_include 'PERSONA_BODY'
      _(result.system_prompt).must_include '## Assignment'
      _(result.system_prompt).must_include 'ASSIGNMENT_BODY'
      _(result.system_prompt).must_include '## Reference Solution'
      _(result.system_prompt).must_include 'SOLUTION_BODY'
      _(result.system_prompt).must_include '### Hw2.Rmd'
      _(result.system_prompt).must_include 'CODE'
    end
  end
end
