# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::WorkspaceEditGate do
  WEG = Tyla::Values::WorkspaceEditGate

  def overview = 'workspace overview present'

  def ctx_with(*paths)
    paths.map { |p| "### #{p}\n1| x <- 1\n" }.join
  end

  def edit(path, key_style: :string)
    patch = { 'start_line' => 1, 'search' => 'x', 'replace' => 'y' }
    if key_style == :symbol
      { type: 'edit_file', path: path, patches: [patch.transform_keys(&:to_sym)] }
    else
      { 'type' => 'edit_file', 'path' => path, 'patches' => [patch] }
    end
  end

  def load(path) = { 'type' => 'load_file', 'path' => path }

  # W1 — inert without workspace_overview
  it 'W1: is inert when workspace_overview is nil' do
    actions = [edit('hw2.R')]
    result = WEG.call(actions: actions, file_context: ctx_with('hw2.R'), workspace_overview: nil)
    _(result).must_equal [actions, false]
  end

  it 'W1b: is inert when workspace_overview is blank string' do
    actions = [edit('hw2.R')]
    result = WEG.call(actions: actions, file_context: ctx_with('hw2.R'), workspace_overview: '')
    _(result).must_equal [actions, false]
  end

  # W2 — edit on already-loaded path passes through
  it 'W2: passes edit_file through when path is loaded in file_context' do
    a = edit('hw2.R')
    gated, redirected = WEG.call(actions: [a], file_context: ctx_with('hw2.R'), workspace_overview: overview)
    _(gated).must_equal [a]
    _(redirected).must_equal false
  end

  # W3 — edit on unloaded path → rewritten to load_file
  it 'W3: rewrites edit_file to load_file when path is NOT in file_context' do
    a = edit('hw3.R')
    gated, redirected = WEG.call(actions: [a], file_context: ctx_with('hw2.R'), workspace_overview: overview)
    _(gated).must_equal [load('hw3.R')]
    _(redirected).must_equal true
  end

  # W4 — CRLF header recognised (key regression guard — uses FileContextHeader.normalize via paths)
  it 'W4: CRLF header ### hw2.R\r\n is recognised as loaded; edit passes through' do
    crlf_ctx = "### hw2.R\r\n1| x <- 1\r\n"
    a = edit('hw2.R')
    gated, redirected = WEG.call(actions: [a], file_context: crlf_ctx, workspace_overview: overview)
    _(gated).must_equal [a]
    _(redirected).must_equal false
  end

  # W5 — ./hw2.R normalised to match ### hw2.R
  it 'W5: edit path ./hw2.R normalises to match ### hw2.R header; passes through' do
    a = edit('./hw2.R')
    gated, redirected = WEG.call(actions: [a], file_context: ctx_with('hw2.R'), workspace_overview: overview)
    _(gated).must_equal [a]
    _(redirected).must_equal false
  end

  # W6 — duplicate edits on same unloaded path collapse
  it 'W6: two edit_file on same unloaded path collapse to one load_file; redirected=true' do
    a1 = edit('hw3.R')
    a2 = edit('hw3.R')
    gated, redirected = WEG.call(actions: [a1, a2], file_context: ctx_with('hw2.R'), workspace_overview: overview)
    _(gated).must_equal [load('hw3.R')]
    _(redirected).must_equal true
  end

  # W7 — symbol-keyed and string-keyed actions are handled equally
  it 'W7a: string-keyed edit on unloaded path → string-keyed load_file' do
    a = edit('hw3.R', key_style: :string)
    gated, = WEG.call(actions: [a], file_context: ctx_with('hw2.R'), workspace_overview: overview)
    _(gated.first).must_equal({ 'type' => 'load_file', 'path' => 'hw3.R' })
  end

  it 'W7b: symbol-keyed edit on unloaded path → symbol-keyed load_file' do
    a = edit('hw3.R', key_style: :symbol)
    gated, = WEG.call(actions: [a], file_context: ctx_with('hw2.R'), workspace_overview: overview)
    _(gated.first).must_equal({ type: 'load_file', path: 'hw3.R' })
  end
end
