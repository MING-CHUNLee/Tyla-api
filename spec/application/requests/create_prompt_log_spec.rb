# frozen_string_literal: true

require_relative '../../spec_helper'
require File.join(ROOT, 'app/application/requests/create_prompt_log.rb')

describe Tyla::Request::CreatePromptLog do
  def valid_params(**overrides)
    {
      course_id:          'c1',
      project_id:         'p1',
      student_id:         's1',
      timestamp:          '2026-05-14T10:00:00Z',
      userPrompt:         'hello',
      attack_probability: 0.2,
      evaluation:         'Normal coding question'
    }.merge(overrides)
  end

  describe 'contract validation' do
    it 'is successful with a valid payload' do
      result = Tyla::Request::CreatePromptLog.new.call(valid_params)
      _(result).must_be :success?
    end

    it 'fails when userPrompt is missing' do
      params = valid_params
      params.delete(:userPrompt)
      _(Tyla::Request::CreatePromptLog.new.call(params)).wont_be :success?
    end

    it 'fails when attack_probability is missing' do
      params = valid_params
      params.delete(:attack_probability)
      _(Tyla::Request::CreatePromptLog.new.call(params)).wont_be :success?
    end

    it 'fails when timestamp is not ISO8601' do
      result = Tyla::Request::CreatePromptLog.new.call(valid_params(timestamp: 'yesterday'))
      _(result).wont_be :success?
    end
  end

  describe '.to_entity' do
    it 'maps userPrompt -> prompt' do
      entity = Tyla::Request::CreatePromptLog.to_entity(valid_params)
      _(entity.prompt).must_equal 'hello'
    end

    it 'maps attack_probability verbatim' do
      entity = Tyla::Request::CreatePromptLog.to_entity(valid_params)
      _(entity.attack_probability).must_equal 0.2
    end

    it 'maps evaluation verbatim' do
      entity = Tyla::Request::CreatePromptLog.to_entity(valid_params)
      _(entity.evaluation).must_equal 'Normal coding question'
    end

    it 'parses timestamp into entity.created_at as Time' do
      entity = Tyla::Request::CreatePromptLog.to_entity(valid_params)
      _(entity.created_at).must_equal Time.utc(2026, 5, 14, 10, 0, 0)
    end

    it 'leaves id as nil (set by repository)' do
      entity = Tyla::Request::CreatePromptLog.to_entity(valid_params)
      _(entity.id).must_be_nil
    end

    it 'passes through course_id, project_id, student_id verbatim' do
      entity = Tyla::Request::CreatePromptLog.to_entity(valid_params)
      _(entity.course_id).must_equal 'c1'
      _(entity.project_id).must_equal 'p1'
      _(entity.student_id).must_equal 's1'
    end
  end
end
