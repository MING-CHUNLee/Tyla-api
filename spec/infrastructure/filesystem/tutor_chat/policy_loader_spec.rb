# frozen_string_literal: true

require_relative '../../../spec_helper'

Dir.glob(File.join(ROOT, 'app/infrastructure/filesystem/tutor_chat/policy_loader.rb')).each { |f| require f }

describe Tyla::Infrastructure::Filesystem::PolicyLoader do
  let(:loader) { Tyla::Infrastructure::Filesystem::PolicyLoader.new }

  it 'loads tutor-socratic policy text successfully' do
    text = loader.load('tutor-socratic')
    _(text).wont_be_empty
  end

  it 'loads tutor-guide policy text successfully' do
    text = loader.load('tutor-guide')
    _(text).wont_be_empty
  end

  it 'raises ArgumentError on unknown mode' do
    _ { loader.load('tutor-unknown') }.must_raise ArgumentError
  end

  it 'includes the mode name in the ArgumentError message' do
    err = _ { loader.load('invalid-mode') }.must_raise ArgumentError
    _(err.message).must_include 'invalid-mode'
  end
end
