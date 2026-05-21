# frozen_string_literal: true

require_relative '../../spec_helper'
require 'json'
require File.join(ROOT, 'app/presentation/representers/prompt_log_representer.rb')

describe Tyla::Representer::PromptLog do
  def build_entity(**overrides)
    Tyla::Entity::PromptLog.new(
      {
        id:                 7,
        course_id:          'c1',
        project_id:         'p1',
        student_id:         's1',
        prompt:             'hello',
        attack_probability: 0.1,
        evaluation:         'fine',
        created_at:         Time.utc(2026, 5, 20, 10, 30, 0)
      }.merge(overrides)
    )
  end

  describe '#to_hash' do
    let(:payload) { Tyla::Representer::PromptLog.new(build_entity).to_hash }

    it 'includes every documented field' do
      %w[id course_id project_id student_id prompt attack_probability evaluation created_at]
        .each { |key| _(payload).must_include key }
    end

    it 'preserves scalar types' do
      _(payload['id']).must_equal 7
      _(payload['attack_probability']).must_equal 0.1
      _(payload['evaluation']).must_equal 'fine'
    end

    it 'serializes created_at as an ISO8601 string' do
      _(payload['created_at']).must_equal '2026-05-20T10:30:00Z'
    end

    it 'tolerates a nil created_at' do
      payload = Tyla::Representer::PromptLog.new(build_entity(created_at: nil)).to_hash
      _(payload['created_at']).must_be_nil
    end
  end

  describe '#to_json' do
    it 'round-trips through JSON to the same field set' do
      json = Tyla::Representer::PromptLog.new(build_entity).to_json
      parsed = JSON.parse(json)
      _(parsed['course_id']).must_equal 'c1'
      _(parsed['prompt']).must_equal 'hello'
    end
  end
end
