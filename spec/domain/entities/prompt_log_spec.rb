# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Entity::PromptLog do
  def valid_attrs(**overrides)
    {
      id:                 nil,
      course_id:          'c1',
      project_id:         'p1',
      student_id:         's1',
      prompt:             'hello world',
      attack_probability: 0.1,
      evaluation:         'looks fine',
      created_at:         nil
    }.merge(overrides)
  end

  it 'constructs with valid attributes' do
    log = Tyla::Entity::PromptLog.new(valid_attrs)
    _(log.course_id).must_equal 'c1'
    _(log.attack_probability).must_equal 0.1
    _(log.evaluation).must_equal 'looks fine'
  end

  it 'raises Dry::Struct::Error when required attribute is missing' do
    attrs = valid_attrs
    attrs.delete(:course_id)
    _ { Tyla::Entity::PromptLog.new(attrs) }.must_raise Dry::Struct::Error
  end

  it 'raises when attack_probability is a string (Strict::Float)' do
    _ { Tyla::Entity::PromptLog.new(valid_attrs(attack_probability: '0.1')) }
      .must_raise Dry::Struct::Error
  end

  it 'allows id to be nil' do
    log = Tyla::Entity::PromptLog.new(valid_attrs(id: nil))
    _(log.id).must_be_nil
  end

  it 'allows evaluation to be nil' do
    log = Tyla::Entity::PromptLog.new(valid_attrs(evaluation: nil))
    _(log.evaluation).must_be_nil
  end

  it 'allows attack_probability/evaluation to be nil (pending-row state)' do
    pending = Tyla::Entity::PromptLog.new(
      valid_attrs(attack_probability: nil, evaluation: nil)
    )
    _(pending.attack_probability).must_be_nil
    _(pending.evaluation).must_be_nil
  end

  describe '#to_attr_hash' do
    it 'does not include :id' do
      log = Tyla::Entity::PromptLog.new(valid_attrs(id: 42, created_at: Time.now))
      _(log.to_attr_hash).wont_include :id
    end

    it 'drops nil values (so DB defaults can fire)' do
      log  = Tyla::Entity::PromptLog.new(valid_attrs(attack_probability: nil, created_at: nil))
      hash = log.to_attr_hash
      _(hash).wont_include :attack_probability
      _(hash).wont_include :created_at
    end

    it 'includes a populated created_at (client-supplied timestamp persists to DB)' do
      ts   = Time.utc(2026, 5, 14, 10, 0, 0)
      log  = Tyla::Entity::PromptLog.new(valid_attrs(created_at: ts))
      _(log.to_attr_hash[:created_at]).must_equal ts
    end

    it 'includes the other persisted attributes' do
      log  = Tyla::Entity::PromptLog.new(valid_attrs(created_at: Time.now))
      hash = log.to_attr_hash
      %i[course_id project_id student_id prompt attack_probability evaluation]
        .each { |k| _(hash).must_include k }
    end
  end
end
