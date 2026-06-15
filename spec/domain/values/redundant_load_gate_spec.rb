# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::RedundantLoadGate do
  describe '.call' do
    def ctx
      "### hw2.R\n1| x <- 1\n2| y <- 2\n### Hw2.Rmd\n1| # Title\n"
    end

    def load_action(path)
      { 'type' => 'load_file', 'path' => path }
    end

    # ── Inert conditions ─────────────────────────────────────────────────────

    it 'is inert when file_context is nil' do
      actions = [load_action('hw2.R')]
      _(Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: nil)).must_equal [actions, false]
    end

    it 'is inert when file_context is empty string' do
      actions = [load_action('hw2.R')]
      _(Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: '')).must_equal [actions, false]
    end

    it 'is inert when file_context has no ### headers' do
      actions = [load_action('hw2.R')]
      result = Tyla::Values::RedundantLoadGate.call(
        actions: actions, file_context: "## File Contents\nhw2.R\n"
      )
      _(result).must_equal [actions, false]
    end

    # ── Core drop logic ──────────────────────────────────────────────────────

    it 'drops a load_file whose path is already in file_context; dropped=true' do
      actions = [load_action('hw2.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal []
      _(dropped).must_equal true
    end

    it 'keeps a load_file for a path NOT in file_context; dropped=false' do
      actions = [load_action('hw3.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal [load_action('hw3.R')]
      _(dropped).must_equal false
    end

    it 'mixed actions: drops only the already-loaded path, keeps the unloaded one' do
      actions = [load_action('hw2.R'), load_action('hw3.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal [load_action('hw3.R')]
      _(dropped).must_equal true
    end

    it 'drops both when both paths are already loaded' do
      actions = [load_action('hw2.R'), load_action('Hw2.Rmd')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal []
      _(dropped).must_equal true
    end

    # ── Intra-reply dedup ────────────────────────────────────────────────────

    it 'collapses intra-reply duplicate load_file for an unloaded path to one; dropped=true' do
      actions = [load_action('hw3.R'), load_action('hw3.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal [load_action('hw3.R')]
      _(dropped).must_equal true
    end

    it 'collapses intra-reply duplicate for an already-loaded path (both dropped)' do
      actions = [load_action('hw2.R'), load_action('hw2.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal []
      _(dropped).must_equal true
    end

    # ── Path normalization ───────────────────────────────────────────────────

    it 'normalizes ./hw2.R to match ### hw2.R header' do
      actions = [load_action('./hw2.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal []
      _(dropped).must_equal true
    end

    it 'normalizes backslash path to match forward-slash header' do
      fc      = "### subdir/file.R\n1| x <- 1\n"
      actions = [load_action('subdir\\file.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: fc)
      _(result).must_equal []
      _(dropped).must_equal true
    end

    # ── Non-load_file actions are untouched ──────────────────────────────────

    it 'passes non-load_file actions through unchanged' do
      edit = { 'type' => 'edit_file', 'path' => 'hw2.R',
               'patches' => [{ 'start_line' => 1, 'search' => 'x', 'replace' => 'y' }] }
      actions = [edit, load_action('hw2.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal [edit]
      _(dropped).must_equal true
    end

    it 'symbol-keyed load_file action is also dropped when path matches' do
      actions = [{ type: 'load_file', path: 'hw2.R' }]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: ctx)
      _(result).must_equal []
      _(dropped).must_equal true
    end

    # ── CRLF header regression ───────────────────────────────────────────────

    it 'CRLF header ### hw2.R\r\n is recognised as loaded; redundant load is dropped' do
      crlf_ctx = "### hw2.R\r\n1| x <- 1\r\n"
      actions  = [load_action('hw2.R')]
      result, dropped = Tyla::Values::RedundantLoadGate.call(actions: actions, file_context: crlf_ctx)
      _(result).must_equal []
      _(dropped).must_equal true
    end
  end
end
