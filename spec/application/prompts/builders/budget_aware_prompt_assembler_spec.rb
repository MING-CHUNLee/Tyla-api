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

  describe 'workspace_overview (file listing) injection' do
    it 'renders the overview section and suppresses the fixture student file when it fits' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:            '',
        assignment:         '',
        solution:           '',
        student_file:       { path: 'Hw2.Rmd', content: 'FIXTURE_STUDENT_FILE_MARKER' },
        history:            [],
        user_prompt:        '',
        endpoint:           GITHUB_ENDPOINT,
        workspace_overview: 'OVERVIEW_LISTING_MARKER'
      )

      _(result.overflow?).must_equal false
      _(result.workspace_overview_dropped).must_equal false
      _(result.system_prompt).must_include '## Student Workspace (overview)'
      _(result.system_prompt).must_include 'OVERVIEW_LISTING_MARKER'
      _(result.system_prompt).wont_include '## Student Workspace Files'
      _(result.system_prompt).wont_include 'FIXTURE_STUDENT_FILE_MARKER'
    end

    it 'lets workspace_overview and file_context coexist (both sections, fixture suppressed)' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:            '',
        assignment:         '',
        solution:           '',
        student_file:       { path: 'Hw2.Rmd', content: 'FIXTURE_STUDENT_FILE_MARKER' },
        history:            [],
        user_prompt:        '',
        endpoint:           GITHUB_ENDPOINT,
        file_context:       'LIVE_FILE_CONTEXT_MARKER',
        workspace_overview: 'OVERVIEW_LISTING_MARKER'
      )

      _(result.system_prompt).must_include '## Student Workspace (overview)'
      _(result.system_prompt).must_include 'OVERVIEW_LISTING_MARKER'
      _(result.system_prompt).must_include '## Student Workspace (live)'
      _(result.system_prompt).must_include 'LIVE_FILE_CONTEXT_MARKER'
      _(result.system_prompt).wont_include 'FIXTURE_STUDENT_FILE_MARKER'
    end

    it 'drops an oversized workspace_overview whole, sets the flag, and frees budget back to history' do
      # 30_000 chars / 3.5 ≈ 8572 tokens — alone exceeds the 8 K cap, so the
      # overview is dropped whole. The freed budget then admits the small turn.
      history = [{ role: 'user', content: 'keep me' }]

      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:            '',
        assignment:         '',
        solution:           '',
        student_file:       { path: 'x', content: '' },
        history:            history,
        user_prompt:        '',
        endpoint:           GITHUB_ENDPOINT,
        workspace_overview: 'O' * 30_000
      )

      _(result.overflow?).must_equal false
      _(result.workspace_overview_dropped).must_equal true
      _(result.system_prompt).wont_include '## Student Workspace (overview)'
      _(result.history.size).must_equal 1
      _(result.history_turns_dropped).must_equal 0
    end

    it 'frees a dropped overview budget to file_context (overview drops, live block still fits)' do
      # Overview is just over the remaining budget on its own; once dropped, the
      # smaller file_context fits. base = 200 overhead; budget 8000 → remaining 7800.
      # overview ≈ 7900 tokens (27_650 chars) > 7800 → dropped; file_context small → kept.
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:            '',
        assignment:         '',
        solution:           '',
        student_file:       { path: 'x', content: '' },
        history:            [],
        user_prompt:        '',
        endpoint:           GITHUB_ENDPOINT,
        file_context:       'LIVE_FILE_CONTEXT_MARKER',
        workspace_overview: 'O' * 27_650
      )

      _(result.workspace_overview_dropped).must_equal true
      _(result.student_file_dropped).must_equal false
      _(result.system_prompt).wont_include '## Student Workspace (overview)'
      _(result.system_prompt).must_include 'LIVE_FILE_CONTEXT_MARKER'
    end
  end

  describe 'strip_section_headings: ## headings removed, ### path and line-prefixed ## preserved' do
    def call_with_file_context(raw)
      Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:      '',
        assignment:   '',
        solution:     '',
        student_file: { path: 'x', content: '' },
        history:      [],
        user_prompt:  '',
        endpoint:     GITHUB_ENDPOINT,
        file_context: raw
      )
    end

    it 'removes ## Files Loaded On Request heading from live_context' do
      fc = "## Files Loaded On Request\n### hw2.R\n 1| x <- 1\n### Hw2.Rmd\n  1| ---\n"
      result = call_with_file_context(fc)
      _(result.system_prompt).must_include '### hw2.R'
      _(result.system_prompt).must_include '### Hw2.Rmd'
      _(result.system_prompt).wont_include '## Files Loaded On Request'
    end

    it 'removes multiple ## headings (## File Contents + ## Files Loaded On Request)' do
      fc = "## File Contents\n### hw2.R\n 1| x <- 1\n## Files Loaded On Request\n### Hw2.Rmd\n  1| ---\n"
      result = call_with_file_context(fc)
      _(result.system_prompt).wont_include '## File Contents'
      _(result.system_prompt).wont_include '## Files Loaded On Request'
      _(result.system_prompt).must_include '### hw2.R'
      _(result.system_prompt).must_include '### Hw2.Rmd'
    end

    it 'passes through file_context unchanged when it has no ## headings (regression)' do
      fc = "### hw2.R\n 1| x <- 1\n  2| y <- 2\n"
      result = call_with_file_context(fc)
      _(result.system_prompt).must_include '### hw2.R'
      _(result.system_prompt).must_include ' 1| x <- 1'
    end

    it 'preserves line-prefixed ## content such as " 1| ## Question 2"' do
      fc = "### Hw2.Rmd\n  1| ## Question 2\n  2| x <- 1\n"
      result = call_with_file_context(fc)
      _(result.system_prompt).must_include '  1| ## Question 2'
    end
  end

  describe 'composition' do
    it 'renders persona, assignment, solution and student file when include_solution is set' do
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:          'PERSONA_BODY',
        assignment:       'ASSIGNMENT_BODY',
        solution:         'SOLUTION_BODY',
        student_file:     { path: 'Hw2.Rmd', content: 'CODE' },
        history:          [],
        user_prompt:      'q',
        endpoint:         GITHUB_ENDPOINT,
        include_solution: true
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

  describe 'hybrid lazy solution (include_solution:)' do
    def call_assembler(include_solution:, solution: 'SOLUTION_BODY', history: [])
      Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona:          'PERSONA_BODY',
        assignment:       'ASSIGNMENT_BODY',
        solution:         solution,
        student_file:     { path: 'Hw2.Rmd', content: 'CODE' },
        history:          history,
        user_prompt:      'q',
        endpoint:         GITHUB_ENDPOINT,
        include_solution: include_solution
      )
    end

    it 'omits the solution by default (round 1): no section, manifest advertises load_reference' do
      result = call_assembler(include_solution: false)
      _(result.system_prompt).wont_include '## Reference Solution'
      _(result.system_prompt).wont_include 'SOLUTION_BODY'
      _(result.system_prompt).must_include '## Available Course Materials'
      _(result.system_prompt).must_include 'load_reference'
      _(result.system_prompt).must_include 'ASSIGNMENT_BODY'   # assignment stays eager
    end

    it 'does not count solution tokens in the round-1 base (oversized solution cannot overflow round 1)' do
      # 30_000 chars ≈ 8572 tokens — alone exceeds the 8 K cap. Round 1 must
      # ignore it entirely: no overflow, and the freed budget admits history.
      result = call_assembler(include_solution: false, solution: 'S' * 30_000,
                              history: [{ role: 'user', content: 'keep me' }])
      _(result.overflow?).must_equal false
      _(result.history.size).must_equal 1
    end

    it 'counts solution tokens as mandatory on round 2 — same 413 boundary as the old eager base' do
      # Regression guard: round-2 base = persona + assignment + solution +
      # prompt + overhead, exactly the pre-hybrid formula, so a solution that
      # overflowed yesterday overflows today and nothing new sneaks past.
      result = call_assembler(include_solution: true, solution: 'S' * 30_000)
      _(result.overflow?).must_equal true
      _(result.system_prompt).must_be_nil
    end

    it 'squeezes droppables (history), never the solution, when round 2 is tight' do
      # base(true) = persona(4) + assignment(5) + solution(2000) + prompt(1) + 200 = 2210
      # remaining = 8000 - 2210 = 5790; CODE file fits; a 5800-token turn does not.
      big_turn = { role: 'user', content: 'h' * 20_300 }   # ≈ 5800 tokens + 4 role
      result   = call_assembler(include_solution: true, solution: 'S' * 7_000,
                                history: [big_turn])
      _(result.overflow?).must_equal false
      _(result.system_prompt).must_include '## Reference Solution'
      _(result.history_turns_dropped).must_equal 1
    end
  end

  describe 'Option C: session_turns compression (plan 2026-06-15 §4.3)' do
    # A realistic completed turn: a question, a prose reply, an edit suggestion,
    # and a headers-only block naming the file the model inspected last turn.
    def sample_turn(overrides = {})
      {
        'prompt'          => 'How do I fix the mean call?',
        'prose'           => 'Use na.rm = TRUE so NAs are ignored.',
        'context_headers' => "### hw2.R\n",
        'actions'         => [
          { 'type' => 'edit_file',
            'path' => 'hw2.R',
            'patches' => [{ 'start_line' => 3, 'search' => 'mean(x)', 'replace' => 'mean(x, na.rm = TRUE)' }] }
        ]
      }.merge(overrides)
    end

    def call_with(session_turns:, **extra)
      Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona: '',
        assignment: '',
        solution: '',
        student_file: { path: 'x', content: '' },
        history: [],
        user_prompt: '',
        endpoint: GITHUB_ENDPOINT,
        session_turns: session_turns,
        **extra
      )
    end

    it '(a) serializes session_turns into user-first [{role, content}] pairs' do
      result = call_with(session_turns: [sample_turn])

      _(result.overflow?).must_equal false
      _(result.history.size).must_equal 2
      user, assistant = result.history
      _(user[:role]).must_equal 'user'
      _(assistant[:role]).must_equal 'assistant'
      # User entry carries the intent plus the neutral re-inspect placeholder.
      _(user[:content]).must_include 'How do I fix the mean call?'
      _(user[:content]).must_include 'call load_file'
      _(user[:content]).must_include 'hw2.R'
      # Assistant entry carries prose + a *suggested* (not applied) edit.
      _(assistant[:content]).must_include 'na.rm = TRUE'
      _(assistant[:content]).must_include 'Suggested editing `hw2.R`'
    end

    it '(b) ignores legacy history and prefers session_turns when both are sent' do
      legacy = [{ role: 'user', content: 'LEGACY_HISTORY_MARKER' }]
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona: '', assignment: '', solution: '',
        student_file: { path: 'x', content: '' },
        history: legacy, user_prompt: '', endpoint: GITHUB_ENDPOINT,
        session_turns: [sample_turn]
      )

      _(result.history.size).must_equal 2
      _(result.history.map { |h| h[:content] }.join).wont_include 'LEGACY_HISTORY_MARKER'
    end

    it '(b) falls back to the legacy history path when session_turns is absent/empty' do
      legacy = [{ role: 'user', content: 'LEGACY_HISTORY_MARKER' }]
      result = Tyla::Prompts::BudgetAwarePromptAssembler.call(
        persona: '', assignment: '', solution: '',
        student_file: { path: 'x', content: '' },
        history: legacy, user_prompt: '', endpoint: GITHUB_ENDPOINT,
        session_turns: []
      )

      _(result.history).must_equal legacy
    end

    it '(c) compresses before trimming: a turn whose raw prompt would overflow still fits once serialized' do
      # persona ≈ 7700 tok → base 7900 → remaining ≈ 100 tok of history budget.
      # The raw prompt embeds a 4 000-char pasted code block (≈1143 tok) that
      # could never fit in 100 tok; strip_pasted_code collapses it to a short
      # marker, so the serialized pair fits. Trim seeing the *compressed* cost is
      # the whole point of serializing before trim_history.
      pasted = "Look at this:\n```r\n#{'z' * 4_000}\n```"
      result = call_with(
        session_turns: [sample_turn('prompt' => pasted, 'context_headers' => '')],
        persona: 'P' * 26_950
      )

      _(result.overflow?).must_equal false
      _(result.history.size).must_equal 2
      joined = result.history.map { |h| h[:content] }.join
      _(joined).must_include '[pasted code omitted'
      _(joined).wont_include 'zzzz'   # the bulky pasted code never reaches the wire
    end

    it 'drops a dangling assistant so the trimmed window never starts on assistant (Anthropic 400 guard)' do
      # Tight budget admits only the cheap assistant half of the pair; the
      # expensive user half does not fit. The leading-assistant guard then sheds
      # the orphan rather than shipping an assistant-first history.
      big_prompt = 'q ' * 250   # ≈500 chars ≈143 tok user entry, no code fence to strip
      result = call_with(
        session_turns: [sample_turn('prompt' => big_prompt, 'prose' => 'ok', 'context_headers' => '', 'actions' => [])],
        persona: 'P' * 26_950
      )

      _(result.overflow?).must_equal false
      _(result.history).must_equal []
      _(result.history_turns_dropped).must_equal 2
    end
  end
end
