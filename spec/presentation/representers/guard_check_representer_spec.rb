# frozen_string_literal: true

require_relative '../../spec_helper'
require 'json'
require File.join(ROOT, 'app/presentation/representers/guard_check_representer.rb')

describe Tyla::Representer::GuardCheck do
  def build_dto(**overrides)
    Tyla::Response::GuardCheck.new(
      **{
        log_id:  101,
        status:  'done',
        refusal: nil,
        usage:   { input_tokens: 50, output_tokens: 8 }
      }.merge(overrides)
    )
  end

  describe '#to_hash' do
    it 'emits every documented field on a done DTO' do
      payload = Tyla::Representer::GuardCheck.new(build_dto).to_hash
      %w[log_id status refusal usage].each { |key| _(payload).must_include key }
      _(payload['log_id']).must_equal 101
      _(payload['status']).must_equal 'done'
      _(payload['refusal']).must_be_nil
      _(payload['usage'][:input_tokens]).must_equal 50
    end

    it 'emits a non-null refusal on a forbidden DTO' do
      dto = build_dto(
        status:  'forbidden',
        refusal: "Let's redirect...",
        usage:   { input_tokens: 80, output_tokens: 12 }
      )
      payload = Tyla::Representer::GuardCheck.new(dto).to_hash
      _(payload).must_include 'refusal'
      _(payload['refusal']).must_equal "Let's redirect..."
      _(payload['usage'][:input_tokens]).must_equal 80
    end

    it 'renders refusal and usage as null on an unavailable DTO' do
      dto = build_dto(status: 'unavailable', refusal: nil, usage: nil)
      payload = Tyla::Representer::GuardCheck.new(dto).to_hash
      _(payload).must_include 'refusal'
      _(payload).must_include 'usage'
      _(payload['refusal']).must_be_nil
      _(payload['usage']).must_be_nil
    end
  end

  describe '#to_json' do
    it 'round-trips through JSON to the same field set' do
      json   = Tyla::Representer::GuardCheck.new(build_dto).to_json
      parsed = JSON.parse(json)
      %w[log_id status refusal usage].each { |key| _(parsed).must_include key }
      _(parsed['status']).must_equal 'done'
    end

    it 'serializes an unavailable DTO with JSON null refusal and usage' do
      dto    = build_dto(status: 'unavailable', refusal: nil, usage: nil)
      json   = Tyla::Representer::GuardCheck.new(dto).to_json
      parsed = JSON.parse(json)
      _(parsed).must_include 'refusal'
      _(parsed).must_include 'usage'
      _(parsed['refusal']).must_be_nil
      _(parsed['usage']).must_be_nil
    end
  end
end
