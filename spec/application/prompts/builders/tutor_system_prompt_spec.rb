# frozen_string_literal: true

require_relative '../../../spec_helper'

describe Tyla::Prompts::TutorSystemPrompt do
  describe '.build' do
    it 'returns the policy text when no solution or files provided' do
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: []
      )
      _(result).must_equal 'POLICY'
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
      big = (Array.new(500) { |i| "line#{i}" }.join("\n") + "\n")
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
