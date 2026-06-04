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
