# frozen_string_literal: true

require_relative '../../spec_helper'
require File.join(ROOT, 'app/application/requests/tutor_chat.rb')

describe Tyla::Request::TutorChat do
  def valid_params(**overrides)
    {
      course_id:    'CSDS',
      project_id:   'HW2',
      student_id:   'stu-abc',
      guard_log_id: 42,
      prompt:       'Why is the FD rule least sensitive to outliers?'
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

    %i[course_id project_id student_id guard_log_id prompt].each do |field|
      it "fails when #{field} is missing" do
        params = valid_params
        params.delete(field)
        _(Tyla::Request::TutorChat.new.call(params)).wont_be :success?
      end
    end

    it 'fails when guard_log_id is not coercible to an integer' do
      _(Tyla::Request::TutorChat.new.call(valid_params(guard_log_id: 'not-a-number'))).wont_be :success?
    end

    it 'coerces a numeric-string guard_log_id to an integer' do
      result = Tyla::Request::TutorChat.new.call(valid_params(guard_log_id: '42'))
      _(result).must_be :success?
      _(result.to_h[:guard_log_id]).must_equal 42
    end

    it 'accepts a file_context string' do
      params = valid_params(file_context: "## Project Context\nWorking dir: ...")
      _(Tyla::Request::TutorChat.new.call(params)).must_be :success?
    end

    it 'succeeds when file_context is absent (optional)' do
      _(Tyla::Request::TutorChat.new.call(valid_params)).must_be :success?
    end

    it 'accepts a workspace_overview string and preserves it through to_h' do
      params = valid_params(workspace_overview: "## Project Context\nR scripts (.R): hw2.R")
      result = Tyla::Request::TutorChat.new.call(params)
      _(result).must_be :success?
      _(result.to_h[:workspace_overview]).must_equal "## Project Context\nR scripts (.R): hw2.R"
    end

    it 'accepts workspace_overview and file_context together' do
      params = valid_params(workspace_overview: 'listing', file_context: "### hw2.R\n  1| x")
      _(Tyla::Request::TutorChat.new.call(params)).must_be :success?
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

  describe 'session_turns (Option C)' do
    it 'accepts a well-formed session_turns array' do
      params = valid_params(session_turns: [
                              {
                                prompt:          'How do I read the CSV?',
                                prose:           'Use read.csv with the right path.',
                                context_headers: "### hw2.R\n",
                                actions:         [{ type: 'load_file', path: 'hw2.R' }]
                              }
                            ])
      _(Tyla::Request::TutorChat.new.call(params)).must_be :success?
    end

    it 'accepts a session_turn with only the required prompt' do
      params = valid_params(session_turns: [{ prompt: 'just an intent' }])
      _(Tyla::Request::TutorChat.new.call(params)).must_be :success?
    end

    it 'preserves session_turns through to_h' do
      turn   = { prompt: 'hi', prose: 'hello' }
      result = Tyla::Request::TutorChat.new.call(valid_params(session_turns: [turn]))
      _(result).must_be :success?
      _(result.to_h[:session_turns].first[:prompt]).must_equal 'hi'
    end

    it 'fails when a session_turn is missing prompt' do
      params = valid_params(session_turns: [{ prose: 'no prompt here' }])
      _(Tyla::Request::TutorChat.new.call(params)).wont_be :success?
    end

    it 'fails when a session_turn prompt is blank' do
      params = valid_params(session_turns: [{ prompt: '' }])
      _(Tyla::Request::TutorChat.new.call(params)).wont_be :success?
    end

    it 'fails when actions is not an array of hashes' do
      params = valid_params(session_turns: [{ prompt: 'p', actions: ['not-a-hash'] }])
      _(Tyla::Request::TutorChat.new.call(params)).wont_be :success?
    end

    it 'fails when session_turns exceeds the 500 KB limit' do
      big   = 'x' * 100
      turns = Array.new(6000) { { prompt: big } }
      result = Tyla::Request::TutorChat.new.call(valid_params(session_turns: turns))
      _(result).wont_be :success?
      _(result.errors.to_h).must_include :session_turns
    end

    it 'still accepts a legacy history-only request (backward compatible)' do
      params = valid_params(history: [
                              { role: 'user',      content: 'first turn' },
                              { role: 'assistant', content: 'reply' }
                            ])
      _(Tyla::Request::TutorChat.new.call(params)).must_be :success?
    end

    it 'accepts session_turns and history together (transition period)' do
      params = valid_params(
        history:       [{ role: 'user', content: 'old' }],
        session_turns: [{ prompt: 'new' }]
      )
      _(Tyla::Request::TutorChat.new.call(params)).must_be :success?
    end
  end
end
