# frozen_string_literal: true

require_relative '../../spec_helper'
require File.join(ROOT, 'app/application/requests/tutor_chat.rb')

describe Tyla::Request::TutorChat do
  def valid_params(**overrides)
    {
      course_id:  'CSDS',
      project_id: 'HW2',
      student_id: 'stu-abc',
      prompt:     'Why is the FD rule least sensitive to outliers?'
    }.merge(overrides)
  end

  describe 'contract validation' do
    it 'succeeds with the minimum valid payload (no history)' do
      _(Tyla::Request::TutorChat.new.call(valid_params)).must_be :success?
    end

    it 'succeeds with a well-formed history array' do
      params = valid_params(history: [
                              { role: 'user',      content: 'first turn' },
                              { role: 'assistant', content: 'reply' }
                            ])
      _(Tyla::Request::TutorChat.new.call(params)).must_be :success?
    end

    %i[course_id project_id student_id prompt].each do |field|
      it "fails when #{field} is missing" do
        params = valid_params
        params.delete(field)
        _(Tyla::Request::TutorChat.new.call(params)).wont_be :success?
      end
    end

    it 'fails when a history entry is missing role' do
      params = valid_params(history: [{ content: 'no role' }])
      _(Tyla::Request::TutorChat.new.call(params)).wont_be :success?
    end

    it 'fails when history exceeds the 500 KB limit' do
      big = 'x' * 100
      huge_history = Array.new(6000) { { role: 'user', content: big } }
      result = Tyla::Request::TutorChat.new.call(valid_params(history: huge_history))
      _(result).wont_be :success?
      _(result.errors.to_h).must_include :history
    end
  end
end
