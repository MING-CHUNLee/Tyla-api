# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::EditPatchContentGate do
  describe '.call' do
    # A file_context snippet with hw2.R lines 1–3 and 69.
    def ctx
      "### hw2.R\n1| x <- 1\n2| y <- 2\n3| z <- 3\n69| old\n"
    end

    def edit_action(path: 'hw2.R', start_line: 1, search: 'x <- 1', replace: 'x <- 99')
      { 'type' => 'edit_file', 'path' => path,
        'patches' => [{ 'start_line' => start_line, 'search' => search, 'replace' => replace }] }
    end

    it 'is inert when file_context is nil' do
      actions = [edit_action]
      _(Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: nil)).must_equal [actions, false]
    end

    it 'is inert when file_context is empty' do
      actions = [edit_action]
      _(Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: '')).must_equal [actions, false]
    end

    it 'is inert when file_context has no ### headers' do
      actions = [edit_action]
      result = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: "## Old Format\nx <- 1\n")
      _(result).must_equal [actions, false]
    end

    it 'leaves non-edit_file actions unchanged' do
      actions = [{ 'type' => 'load_file', 'path' => 'hw2.R' }]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: ctx)
      _(result).must_equal actions
      _(redirected).must_equal false
    end

    it 'leaves an edit_file unchanged when its path is not in file_context' do
      actions = [edit_action(path: 'hw3.R')]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: ctx)
      _(result).must_equal actions
      _(redirected).must_equal false
    end

    it 'leaves an edit_file unchanged when content matches' do
      actions = [edit_action(start_line: 1, search: 'x <- 1', replace: 'x <- 99')]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: ctx)
      _(result).must_equal actions
      _(redirected).must_equal false
    end

    it 'redirects to load_file when content mismatches' do
      actions = [edit_action(start_line: 1, search: 'x <- WRONG', replace: 'x <- 99')]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: ctx)
      _(result).must_equal [{ 'type' => 'load_file', 'path' => 'hw2.R' }]
      _(redirected).must_equal true
    end

    it 'matches across a sparse file_context (line 69 present, lines in between absent)' do
      actions = [edit_action(start_line: 69, search: 'old', replace: 'new')]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: ctx)
      _(result).must_equal actions
      _(redirected).must_equal false
    end

    it 'skips validation for a patch when required lines are absent from the snapshot' do
      # file_context only has line 69; a 2-line search starting at 69 needs line 70 too.
      sparse = "### hw2.R\n69| old\n"
      actions = [edit_action(start_line: 69, search: "old\nnext", replace: 'new')]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: sparse)
      _(result).must_equal actions   # incomplete snapshot → pass through, let frontend verify
      _(redirected).must_equal false
    end

    it 'matches despite CRLF in file_context vs LF in search' do
      crlf_ctx = "### hw2.R\r\n1| x <- 1\r\n2| y <- 2\r\n"
      actions = [edit_action(start_line: 1, search: "x <- 1\n", replace: 'x <- 99')]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: crlf_ctx)
      _(result).must_equal actions
      _(redirected).must_equal false
    end

    it 'skips validation when start_line is absent (XML fallback compatibility)' do
      actions = [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                   'patches' => [{ 'search' => 'x <- 1', 'replace' => 'x <- 2' }] }]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: ctx)
      _(result).must_equal actions
      _(redirected).must_equal false
    end

    it 'handles symbol-keyed actions and mirrors key style in the redirect' do
      actions = [{ type: 'edit_file', path: 'hw2.R',
                   patches: [{ start_line: 1, search: 'WRONG', replace: 'x <- 99' }] }]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: actions, file_context: ctx)
      _(result).must_equal [{ type: 'load_file', path: 'hw2.R' }]
      _(redirected).must_equal true
    end

    it 'deduplicates load_file redirects when multiple edit_file actions for the same path mismatch' do
      two_edits = [edit_action(start_line: 1, search: 'WRONG', replace: 'a'),
                   edit_action(start_line: 2, search: 'WRONG', replace: 'b')]
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: two_edits, file_context: ctx)
      _(result.count { |a| a['type'] == 'load_file' }).must_equal 1
      _(redirected).must_equal true
    end

    # ── CRLF header regression ───────────────────────────────────────────────

    it 'CRLF header ### hw2.R\r\n is recognised; content match passes edit through' do
      crlf_ctx = "### hw2.R\r\n1| x <- 1\r\n2| y <- 2\r\n"
      action   = edit_action(start_line: 1, search: "x <- 1\r\n", replace: 'x <- 99')
      result, redirected = Tyla::Values::EditPatchContentGate.call(actions: [action], file_context: crlf_ctx)
      _(redirected).must_equal false
      _(result).must_equal [action]
    end
  end
end
