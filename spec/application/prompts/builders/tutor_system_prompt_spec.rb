# frozen_string_literal: true

require_relative '../../../spec_helper'

describe Tyla::Prompts::TutorSystemPrompt do
  describe '.build' do
    it 'returns the policy text (plus the tool use guide) when no solution or files provided' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: []
      )
      _(result).must_include 'POLICY'
      _(result).wont_include '## Student Workspace'
    end

    it 'always appends the tool use guide section' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: []
      )
      _(result).must_include '## Tool Use Guide'
      _(result).must_include 'edit_file'
    end

    it 'renders live_context under "## Student Workspace (live)" and suppresses the fixture files' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [{ path: 'hw.R', content: 'FIXTURE_WIP' }],
        live_context: 'LIVE_WORKSPACE_BLOCK'
      )
      _(result).must_include '## Student Workspace (live)'
      _(result).must_include 'LIVE_WORKSPACE_BLOCK'
      _(result).wont_include '## Student Workspace Files'
      _(result).wont_include 'FIXTURE_WIP'
    end

    it 'renders workspace_overview as "## Student Workspace (overview)" + load-file guide, no line-number guide' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [],
        workspace_overview: 'R scripts (.R): hw2.R'
      )
      _(result).must_include '## Student Workspace (overview)'
      _(result).must_include 'R scripts (.R): hw2.R'
      _(result).must_include '## Loading Workspace Files'
      _(result).must_include 'load_file'
      _(result).wont_include '## Workspace Line Numbers'
    end

    it 'overview guide (B): steers to use already-live files directly, drops the "NOT loaded" lie' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [],
        workspace_overview: 'R scripts (.R): hw2.R'
      )
      guide = result.split('## Loading Workspace Files').last
      _(guide).must_include 'source of truth'
      _(guide).must_include 'use it directly'
      _(guide).must_include 'do NOT call `load_file` for it again'
      _(guide).wont_include 'their contents are NOT loaded'   # the lie that drove the load_file loop
      # Existing safeguards must survive the rewrite.
      _(guide).must_include 'Never invent or guess a "N| "'
      _(guide).must_include 'load_file' # still steers loading for not-yet-live files
    end

    it 'overview guide includes ### path semantic: loaded = ### filename + numbered lines' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [],
        workspace_overview: 'R scripts (.R): hw2.R'
      )
      guide = result.split('## Loading Workspace Files').last
      _(guide).must_include '### filename'
      _(guide).must_include '1| ...'
    end

    it 'lets workspace_overview and live_context coexist (both sections present)' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [],
        live_context: '1| x <- 1',
        workspace_overview: 'R scripts (.R): hw2.R'
      )
      _(result).must_include '## Student Workspace (overview)'
      _(result).must_include '## Student Workspace (live)'
      _(result).must_include '## Workspace Line Numbers'   # live branch still carries it
      _(result).must_include '## Loading Workspace Files'  # overview branch guide
    end

    it 'suppresses the fixture files block when workspace_overview is present (no live_context)' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [{ path: 'hw.R', content: 'FIXTURE_WIP' }],
        workspace_overview: 'R scripts (.R): hw.R'
      )
      _(result).must_include '## Student Workspace (overview)'
      _(result).wont_include '## Student Workspace Files'
      _(result).wont_include 'FIXTURE_WIP'
    end

    it 'tightens the tool use guide: load_file before editing an unloaded file, never invent line numbers' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: []
      )
      guide = result.split('## Tool Use Guide').last
      _(guide).must_include 'Student Workspace (live)'
      _(guide).must_include 'load_file'
      _(guide).must_include 'never guess line numbers'
    end

    it 'appends the line-number guide on the live_context branch (start_line, plain code — no in-search prefix)' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [],
        live_context: '1| x <- 1'
      )
      _(result).must_include '## Workspace Line Numbers'
      _(result).must_include 'set `start_line`'
      _(result).must_include 'plain code'
      _(result).wont_include 'INCLUDING the number prefixes'
    end

    it 'omits the line-number guide on the fixture files branch (no prefixes there)' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [{ path: 'hw.R', content: 'FIXTURE_WIP' }],
        live_context: nil
      )
      _(result).wont_include '## Workspace Line Numbers'
    end

    it 'falls back to the fixture files block when live_context is absent' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [{ path: 'hw.R', content: 'FIXTURE_WIP' }],
        live_context: nil
      )
      _(result).must_include '## Student Workspace Files'
      _(result).must_include 'FIXTURE_WIP'
      _(result).wont_include '## Student Workspace (live)'
    end

    it 'always renders the course-materials manifest, advertising load_reference (hybrid lazy)' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: []
      )
      _(result).must_include '## Available Course Materials'
      _(result).must_include 'Not loaded by default'
      _(result).must_include 'load_reference'
    end

    it 'swaps the manifest for the "already included" variant when the solution is injected' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: 'SOL',
        context_files: []
      )
      _(result).must_include '## Available Course Materials'
      _(result).must_include 'included below'
      _(result).wont_include 'Not loaded by default'
    end

    it 'renders assignment_text as its own ## Assignment section' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        assignment_text: 'ASSIGNMENT_BODY',
        solution_text: '',
        context_files: []
      )
      _(result).must_include "## Assignment\nASSIGNMENT_BODY"
    end

    it 'omits the ## Assignment section when assignment_text is blank' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: []
      )
      _(result).wont_include '## Assignment'
    end

    it 'mentions load_reference in the tool use guide with the logistical-question carve-out' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: []
      )
      guide = result.split('## Tool Use Guide').last
      _(guide).must_include 'load_reference'
      _(guide).must_include 'purely logistical'
    end

    it 'includes solution text section when provided' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: 'SOL',
        context_files: []
      )
      _(result).must_include 'POLICY'
      _(result).must_include '## Reference Solution'
      _(result).must_include 'SOL'
    end

    it 'includes file block when files provided' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [{ path: 'hw.R', content: "x <- 1\n" }]
      )
      _(result).must_include '## Student Workspace Files'
      _(result).must_include '### hw.R'
      _(result).must_include 'x <- 1'
    end

    it 'renders the full file content (no per-file line cap — trimming lives in the assembler)' do
      big = "#{Array.new(500) { |i| "line#{i}" }.join("\n")}\n"
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [{ path: 'big.R', content: big }]
      )
      _(result).wont_include '(truncated'
      _(result).must_include 'line499'
    end
  end
end
