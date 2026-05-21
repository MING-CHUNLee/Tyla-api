# frozen_string_literal: true

require_relative '../../spec_helper'
require File.join(ROOT, 'app/presentation/responses/result.rb')

describe Tyla::Response::Result do
  describe 'status validation' do
    it 'accepts every status in SUCCESS' do
      Tyla::Response::SUCCESS.each do |status|
        _(Tyla::Response::Result.new(status: status).status).must_equal status
      end
    end

    it 'accepts every status in FAILURE' do
      Tyla::Response::FAILURE.each do |status|
        _(Tyla::Response::Result.new(status: status).status).must_equal status
      end
    end

    it 'raises ArgumentError on an unknown status symbol' do
      assert_raises(ArgumentError) { Tyla::Response::Result.new(status: :teapot) }
    end
  end

  describe 'optional fields' do
    it 'defaults message and errors to nil' do
      result = Tyla::Response::Result.new(status: :ok)
      _(result.message).must_be_nil
      _(result.errors).must_be_nil
    end

    it 'preserves message and errors when provided' do
      result = Tyla::Response::Result.new(
        status:  :cannot_process,
        message: 'validation failed',
        errors:  { timestamp: ['must be ISO8601'] }
      )
      _(result.message).must_equal 'validation failed'
      _(result.errors).must_equal(timestamp: ['must be ISO8601'])
    end
  end
end
