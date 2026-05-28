# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::PayloadLimits do
  it 'sets MAX_CONTEXT_FILES_BYTES to 1 MB (1_048_576)' do
    _(Tyla::Values::PayloadLimits::MAX_CONTEXT_FILES_BYTES).must_equal 1_048_576
  end

  it 'sets MAX_HISTORY_BYTES to 500 KB (512_000)' do
    _(Tyla::Values::PayloadLimits::MAX_HISTORY_BYTES).must_equal 512_000
  end
end
