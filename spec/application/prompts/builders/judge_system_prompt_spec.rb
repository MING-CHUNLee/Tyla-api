# frozen_string_literal: true

require_relative '../../../spec_helper'

describe Tyla::Prompts::JudgeSystemPrompt do
  let(:built) { Tyla::Prompts::JudgeSystemPrompt.build }

  it 'returns a non-empty string' do
    _(built).must_be_kind_of String
    _(built.length).must_be :>, 0
  end

  it 'substitutes the jailbreak catalog placeholder' do
    _(built).wont_include '{{jailbreakCatalog}}'
  end

  it 'includes content from the jailbreak catalog' do
    catalog_excerpt = File.read(Tyla::Prompts::JudgeSystemPrompt::CATALOG_PATH).lines.first.strip
    _(built).must_include catalog_excerpt unless catalog_excerpt.empty?
  end

  it 'preserves the JSON response instruction from the template' do
    _(built).must_include 'attack-probability'
  end
end
