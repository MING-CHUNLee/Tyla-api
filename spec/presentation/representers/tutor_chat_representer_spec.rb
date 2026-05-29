# frozen_string_literal: true

require_relative '../../spec_helper'
require 'json'
require File.join(ROOT, 'app/presentation/representers/tutor_chat_representer.rb')

describe Tyla::Representer::TutorChat do
  def build_dto(**overrides)
    Tyla::Response::TutorChat.new(
      **{
        log_id:  101,
        status:  'done',
        content: 'Step 1: ...',
        usage:   { input_tokens: 10, output_tokens: 5 }
      }.merge(overrides)
    )
  end

  describe '#to_hash' do
    it 'emits every documented field on a done DTO' do
      payload = Tyla::Representer::TutorChat.new(build_dto).to_hash
      %w[log_id status content usage].each { |key| _(payload).must_include key }
      _(payload['log_id']).must_equal 101
      _(payload['status']).must_equal 'done'
      _(payload['content']).must_equal 'Step 1: ...'
      _(payload['usage'][:input_tokens]).must_equal 10
    end

    it 'emits a non-null usage on a forbidden DTO (guard-only tokens)' do
      dto = build_dto(
        status:  'forbidden',
        content: "Let's redirect...",
        usage:   { input_tokens: 80, output_tokens: 12 }
      )
      payload = Tyla::Representer::TutorChat.new(dto).to_hash
      _(payload).must_include 'usage'
      _(payload['usage'][:input_tokens]).must_equal 80
    end

    it 'accepts the unavailable status' do
      payload = Tyla::Representer::TutorChat.new(build_dto(status: 'unavailable')).to_hash
      _(payload['status']).must_equal 'unavailable'
    end
  end

  describe '#to_json' do
    it 'round-trips through JSON to the same field set' do
      json   = Tyla::Representer::TutorChat.new(build_dto).to_json
      parsed = JSON.parse(json)
      %w[log_id status content usage].each { |key| _(parsed).must_include key }
      _(parsed['status']).must_equal 'done'
    end

    it 'serializes a forbidden DTO usage as a JSON object (not null)' do
      dto    = build_dto(status: 'forbidden', usage: { input_tokens: 80, output_tokens: 12 })
      json   = Tyla::Representer::TutorChat.new(dto).to_json
      parsed = JSON.parse(json)
      _(parsed).must_include 'usage'
      _(parsed['usage']).wont_be_nil
    end
  end
end
