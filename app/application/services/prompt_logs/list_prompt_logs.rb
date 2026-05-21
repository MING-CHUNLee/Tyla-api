# frozen_string_literal: true

require 'dry/monads'
require 'dry/monads/do'

module Tyla
  module Services
    # Lists prompt logs scoped to a (student_id, course_id, project_id) triple.
    #
    # The repository's find_all is unscoped-friendly, so this service enforces
    # the scope at the application boundary: an unscoped GET would otherwise
    # expose every student's logs (which include attack_probability /
    # evaluation) to any caller.
    class ListPromptLogs
      include Dry::Monads[:result]
      include Dry::Monads::Do

      REQUIRED_FILTERS = %w[student_id course_id project_id].freeze

      def call(params)
        filters  = yield validate_filters(params)
        entities = yield fetch_logs(filters)
        Success(entities)
      end

      private

      def validate_filters(params)
        missing = REQUIRED_FILTERS.reject do |key|
          value = params[key]
          value.is_a?(String) && !value.strip.empty?
        end

        return Success(REQUIRED_FILTERS.each_with_object({}) { |k, h| h[k.to_sym] = params[k] }) if missing.empty?

        Failure[:bad_request, "missing required query parameters: #{missing.join(', ')}"]
      end

      def fetch_logs(filters)
        Success(Repository::PromptLogs.find_all(filters))
      rescue Sequel::Error
        Failure[:db_error, 'could not load prompt logs']
      end
    end
  end
end
