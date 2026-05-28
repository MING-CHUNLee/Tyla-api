# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::Tokenizer do
  describe '.estimate' do
    it 'returns 0 for nil' do
      _(Tyla::Values::Tokenizer.estimate(nil)).must_equal 0
    end

    it 'returns 0 for the empty string' do
      _(Tyla::Values::Tokenizer.estimate('')).must_equal 0
    end

    it 'returns the ceiling of length / CHARS_PER_TOKEN' do
      # 35 chars / 3.5 = 10 exactly
      _(Tyla::Values::Tokenizer.estimate('a' * 35)).must_equal 10
      # 36 chars / 3.5 = 10.28… → ceil = 11
      _(Tyla::Values::Tokenizer.estimate('a' * 36)).must_equal 11
      # 1 char / 3.5 = 0.28… → ceil = 1 (never zero for non-empty input)
      _(Tyla::Values::Tokenizer.estimate('a')).must_equal 1
    end

    it 'is idempotent across calls' do
      text = 'the quick brown fox jumps over the lazy dog'
      a = Tyla::Values::Tokenizer.estimate(text)
      b = Tyla::Values::Tokenizer.estimate(text)
      _(a).must_equal b
    end
  end
end
