# frozen_string_literal: true

require_relative '../../spec_helper'
require 'json'
require File.join(ROOT, 'app/presentation/responses/result.rb')
require File.join(ROOT, 'app/presentation/representers/http_response.rb')

describe Tyla::Representer::HttpResponse do
  def representer_for(**attrs)
    Tyla::Representer::HttpResponse.new(Tyla::Response::Result.new(**attrs))
  end

  describe '#http_status_code' do
    it 'maps :ok to 200' do
      _(representer_for(status: :ok).http_status_code).must_equal 200
    end

    it 'maps :created to 201' do
      _(representer_for(status: :created).http_status_code).must_equal 201
    end

    it 'maps :bad_request to 400' do
      _(representer_for(status: :bad_request).http_status_code).must_equal 400
    end

    it 'maps :not_found to 404' do
      _(representer_for(status: :not_found).http_status_code).must_equal 404
    end

    it 'maps :cannot_process to 422' do
      _(representer_for(status: :cannot_process).http_status_code).must_equal 422
    end

    it 'maps :too_many_requests to 429' do
      _(representer_for(status: :too_many_requests).http_status_code).must_equal 429
    end

    it 'maps :internal_error to 500' do
      _(representer_for(status: :internal_error).http_status_code).must_equal 500
    end
  end

  describe '#to_hash' do
    it 'preserves the status symbol and surfaces message + errors' do
      payload = representer_for(
        status:  :cannot_process,
        message: 'validation failed',
        errors:  { timestamp: ['must be ISO8601'] }
      ).to_hash

      _(payload['status']).must_equal :cannot_process
      _(payload['message']).must_equal 'validation failed'
      _(payload['errors']).must_equal(timestamp: ['must be ISO8601'])
    end

    it 'emits nil for absent message and errors' do
      payload = representer_for(status: :ok).to_hash

      _(payload['status']).must_equal :ok
      _(payload['message']).must_be_nil
      _(payload['errors']).must_be_nil
    end
  end

  describe '#to_json' do
    it 'serializes the status symbol as a JSON string' do
      json = representer_for(status: :not_found, message: 'no log').to_json
      parsed = JSON.parse(json)
      _(parsed['status']).must_equal 'not_found'
      _(parsed['message']).must_equal 'no log'
    end

    it 'round-trips a validation error envelope' do
      json = representer_for(
        status:  :cannot_process,
        message: 'validation failed',
        errors:  { timestamp: ['must be ISO8601'] }
      ).to_json
      parsed = JSON.parse(json)
      _(parsed['status']).must_equal 'cannot_process'
      _(parsed['errors']).must_equal('timestamp' => ['must be ISO8601'])
    end
  end
end
