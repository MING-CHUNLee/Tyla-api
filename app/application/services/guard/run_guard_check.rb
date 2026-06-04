# frozen_string_literal: true

require 'dry/monads'
require 'dry/monads/do'

module Tyla
  module Services
    class RunGuardCheck
      include Dry::Monads[:result]
      include Dry::Monads::Do

      LLM_UNAVAILABLE_EVALUATION = 'llm-unavailable'

      def call(raw_params, headers)
        provider = headers['HTTP_X_LLM_PROVIDER'] || ENV.fetch('LLM_PROVIDER', 'openai')
        api_key  = headers['HTTP_X_LLM_KEY']      || ENV.fetch('OPENAI_API_KEY', nil)
        return Failure[:forbidden, 'missing X-LLM-Key'] if api_key.nil? || api_key.empty?

        model    = headers['HTTP_X_LLM_MODEL']    || nil
        endpoint = headers['HTTP_X_LLM_ENDPOINT'] || nil

        validated = Request::GuardCheck.new.call(raw_params)
        return Failure[:bad_request, 'validation failed', validated.errors.to_h] unless validated.success?

        params = validated.to_h

        llm    = Infrastructure::LlmClient.for(provider: provider, api_key: api_key, model: model, endpoint: endpoint)
        guard  = GuardAgent.new(llm_client: llm)
        result = guard.check(prompt: params[:prompt], mode: nil)

        llm_unavailable = result.probability.nil?

        entity = Entity::PromptLog.new(
          id:                 nil,
          course_id:          params[:course_id],
          project_id:         params[:project_id],
          student_id:         params[:student_id],
          prompt:             params[:prompt],
          attack_probability: result.probability&.fetch(:attack),
          evaluation:         result.reason,
          created_at:         nil
        )
        log = Repository::PromptLogs.create(entity)

        response = build_response(result: result, log_id: log.id, llm_unavailable: llm_unavailable)
        if llm_unavailable
          Success([:unavailable, response])
        else
          Success([result.allowed? ? :done : :forbidden, response])
        end
      rescue Sequel::Error
        Failure[:db_error, 'could not write log entry']
      end

      private

      def build_response(result:, log_id:, llm_unavailable:)
        if llm_unavailable
          return Response::GuardCheck.new(log_id: log_id, status: 'unavailable', refusal: nil, usage: nil)
        end

        allowed = result.allowed?
        Response::GuardCheck.new(
          log_id:  log_id,
          status:  allowed ? 'done' : 'forbidden',
          refusal: allowed ? nil : Values::RefusalTemplates.for,
          usage:   result.usage
        )
      end
    end
  end
end
