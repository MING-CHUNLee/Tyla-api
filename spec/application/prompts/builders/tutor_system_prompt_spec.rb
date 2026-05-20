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

    it 'truncates a file beyond MAX_FILE_LINES' do
      big = (Array.new(Tyla::Values::PayloadLimits::MAX_FILE_LINES + 5) { |i| "line#{i}" }.join("\n") + "\n")
      result = Tyla::Prompts::TutorSystemPrompt.build(
        policy_text: 'POLICY',
        solution_text: '',
        context_files: [{ path: 'big.R', content: big }]
      )
      _(result).must_include '(truncated, showing first 200 lines)'
      _(result).wont_include "line#{Tyla::Values::PayloadLimits::MAX_FILE_LINES + 1}"
    end
  end

  describe '.truncate_history' do
    it 'returns [] for nil' do
      _(Tyla::Prompts::TutorSystemPrompt.truncate_history(nil)).must_equal []
    end

    it 'returns history unchanged when below limit' do
      history = [{ role: 'user', content: 'a' }, { role: 'assistant', content: 'b' }]
      _(Tyla::Prompts::TutorSystemPrompt.truncate_history(history)).must_equal history
    end

    it 'keeps only the last MAX_HISTORY_TURNS * 2 messages' do
      total = Tyla::Values::PayloadLimits::MAX_HISTORY_TURNS * 2 + 4
      history = Array.new(total) { |i| { role: i.even? ? 'user' : 'assistant', content: "m#{i}" } }
      result = Tyla::Prompts::TutorSystemPrompt.truncate_history(history)
      _(result.size).must_equal Tyla::Values::PayloadLimits::MAX_HISTORY_TURNS * 2
      _(result.last).must_equal history.last
    end
  end
end
