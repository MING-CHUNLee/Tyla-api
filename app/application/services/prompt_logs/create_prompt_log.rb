# frozen_string_literal: true

require 'dry/monads'
require 'dry/monads/do'

module Tyla
  module Services
    class CreatePromptLog
      include Dry::Monads[:result]
      include Dry::Monads::Do

      def call(raw_params)
        params = yield normalize_params(raw_params)
        entity = yield validate_and_build(params)
        saved  = yield persist(entity)
        Success(saved)
      end

      private

      def normalize_params(raw_params)
        params = raw_params.dup
        params['attack_probability'] = params.delete('attack-probability') if params.key?('attack-probability')
        Success(params)
      end

      def validate_and_build(params)
        validated = Request::CreatePromptLog.new.call(params)
        return Failure[:cannot_process, 'validation failed', validated.errors.to_h] unless validated.success?

        Success(Request::CreatePromptLog.to_entity(validated.to_h))
      end

      def persist(entity)
        Success(Repository::PromptLogs.create(entity))
      rescue Sequel::Error
        Failure[:db_error, 'could not save prompt log']
      end
    end
  end
end
