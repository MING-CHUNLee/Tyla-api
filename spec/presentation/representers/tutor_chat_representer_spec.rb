# frozen_string_literal: true

require_relative '../../spec_helper'
require 'json'
require File.join(ROOT, 'app/presentation/representers/tutor_chat_representer.rb')

describe Tyla::Representer::TutorChat do
  def build_dto(**overrides)
    Tyla::Response::TutorChat.new(
      log_id: 101,
      status: 'done',
      content: 'Step 1: ...',
      actions: [],
      usage: { input_tokens: 10, output_tokens: 5 }, **overrides
    )
  end

  describe '#to_hash' do
    it 'emits every documented field on a done DTO' do
      payload = Tyla::Representer::TutorChat.new(build_dto).to_hash
      %w[log_id status content actions usage].each { |key| _(payload).must_include key }
      _(payload['log_id']).must_equal 101
      _(payload['status']).must_equal 'done'
      _(payload['content']).must_equal 'Step 1: ...'
      _(payload['usage'][:input_tokens]).must_equal 10
    end

    it 'renders a populated actions array' do
      actions = [{ 'type' => 'load_file', 'path' => 'hw11.R' }]
      payload = Tyla::Representer::TutorChat.new(build_dto(actions: actions)).to_hash
      _(payload['actions']).must_equal actions
    end

    it 'renders an empty actions array as []' do
      payload = Tyla::Representer::TutorChat.new(build_dto(actions: [])).to_hash
      _(payload).must_include 'actions'
      _(payload['actions']).must_equal []
    end

    it 'omits actions and renders usage null on a forbidden DTO' do
      dto = build_dto(
        status:  'forbidden',
        content: "Let's redirect...",
        actions: nil,
        usage:   nil
      )
      payload = Tyla::Representer::TutorChat.new(dto).to_hash
      _(payload).wont_include 'actions'
      _(payload).must_include 'usage'
      _(payload['usage']).must_be_nil
    end

    it 'accepts the unavailable status with an actions array' do
      payload = Tyla::Representer::TutorChat.new(build_dto(status: 'unavailable')).to_hash
      _(payload['status']).must_equal 'unavailable'
      _(payload).must_include 'actions'
    end
  end

  describe '#to_json' do
    it 'round-trips through JSON including actions on a done DTO' do
      json   = Tyla::Representer::TutorChat.new(build_dto(actions: [{ 'type' => 'load_file' }])).to_json
      parsed = JSON.parse(json)
      %w[log_id status content actions usage].each { |key| _(parsed).must_include key }
      _(parsed['status']).must_equal 'done'
      _(parsed['actions']).must_equal [{ 'type' => 'load_file' }]
    end

    it 'omits actions and serializes usage as null on a forbidden DTO' do
      dto    = build_dto(status: 'forbidden', actions: nil, usage: nil)
      json   = Tyla::Representer::TutorChat.new(dto).to_json
      parsed = JSON.parse(json)
      _(parsed).wont_include 'actions'
      _(parsed).must_include 'usage'
      _(parsed['usage']).must_be_nil
    end
  end
end
