# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::EditPatchNormalizer do
  describe '.call' do
    it 'strips a leading "N| " prefix from search and replace' do
      actions = [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                   'patches' => [{ 'start_line' => 9, 'search' => '  9| q <- 1', 'replace' => ' 9| q <- 2' }] }]
      result = Tyla::Values::EditPatchNormalizer.call(actions)
      _(result).must_equal [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                              'patches' => [{ 'start_line' => 9, 'search' => 'q <- 1', 'replace' => 'q <- 2' }] }]
    end

    it 'leaves already-plain patches untouched' do
      actions = [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                   'patches' => [{ 'start_line' => 9, 'search' => 'q <- 1', 'replace' => 'q <- 2' }] }]
      _(Tyla::Values::EditPatchNormalizer.call(actions)).must_equal actions
    end

    it 'strips the prefix from every line of a multi-line patch' do
      actions = [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                   'patches' => [{ 'start_line' => 3,
                                   'search' => "3| a <- 1\n4| b <- 2",
                                   'replace' => "a <- 10\nb <- 20" }] }]
      result = Tyla::Values::EditPatchNormalizer.call(actions)
      _(result.first['patches'].first['search']).must_equal "a <- 1\nb <- 2"
    end

    it 'preserves CRLF line endings while stripping prefixes' do
      actions = [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                   'patches' => [{ 'start_line' => 3, 'search' => "3| a <- 1\r\n4| b <- 2\r\n", 'replace' => 'x' }] }]
      result = Tyla::Values::EditPatchNormalizer.call(actions)
      _(result.first['patches'].first['search']).must_equal "a <- 1\r\nb <- 2\r\n"
    end

    it 'does not mistake an interior pipe in real code for a prefix' do
      actions = [{ 'type' => 'edit_file', 'path' => 'hw2.R',
                   'patches' => [{ 'start_line' => 1, 'search' => 'x <- a | b', 'replace' => 'x <- a & b' }] }]
      _(Tyla::Values::EditPatchNormalizer.call(actions)).must_equal actions
    end

    it 'leaves non-edit_file actions unchanged' do
      actions = [{ 'type' => 'load_file', 'path' => 'hw2.R' },
                 { 'type' => 'execute_script', 'code' => '9| not a prefix here' }]
      _(Tyla::Values::EditPatchNormalizer.call(actions)).must_equal actions
    end

    it 'handles symbol-keyed actions and patches (XML/rewritten style)' do
      actions = [{ type: 'edit_file', path: 'hw2.R',
                   patches: [{ start_line: 9, search: '9| old', replace: 'new' }] }]
      result = Tyla::Values::EditPatchNormalizer.call(actions)
      _(result).must_equal [{ type: 'edit_file', path: 'hw2.R',
                              patches: [{ start_line: 9, search: 'old', replace: 'new' }] }]
    end

    it 'tolerates an edit_file with no patches array' do
      actions = [{ 'type' => 'edit_file', 'path' => 'hw2.R' }]
      _(Tyla::Values::EditPatchNormalizer.call(actions)).must_equal actions
    end
  end
end
