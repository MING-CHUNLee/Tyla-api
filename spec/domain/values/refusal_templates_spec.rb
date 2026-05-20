# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::RefusalTemplates do
  it 'exposes a non-empty TEMPLATES list' do
    _(Tyla::Values::RefusalTemplates::TEMPLATES).must_be_kind_of Array
    _(Tyla::Values::RefusalTemplates::TEMPLATES.size).must_be :>=, 2
    Tyla::Values::RefusalTemplates::TEMPLATES.each do |t|
      _(t).must_be_kind_of String
      _(t.length).must_be :>, 0
    end
  end

  it 'returns a template string for any mode (or nil mode)' do
    _(Tyla::Values::RefusalTemplates.for('tutor-socratic')).must_be_kind_of String
    _(Tyla::Values::RefusalTemplates.for('tutor-guide')).must_be_kind_of String
    _(Tyla::Values::RefusalTemplates.for(nil)).must_be_kind_of String
  end

  it 'returns one of the defined templates' do
    sample = Tyla::Values::RefusalTemplates.for
    _(Tyla::Values::RefusalTemplates::TEMPLATES).must_include sample
  end
end
