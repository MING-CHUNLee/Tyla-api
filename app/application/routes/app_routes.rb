# frozen_string_literal: true

module Tyla
  class Api
    route do |r|
      r.on 'api' do
        r.on 'v1' do
          r.on 'prompt_logs' do
            # POST /api/v1/prompt_logs
            # Accepts the CLI guard-log payload; see
            # Request::CreatePromptLog for the validated input shape.
            r.post do
              contract = Request::CreatePromptLog.new
              result   = contract.call(r.params)

              r.halt(422, { errors: result.errors.to_h }.to_json) unless result.success?

              entity = Request::CreatePromptLog.to_entity(result.to_h)
              saved  = Repository::PromptLogs.create(entity)

              response.status = 201
              Representer::PromptLog.new(saved).to_hash
            end

            # GET /api/v1/prompt_logs?student_id=X&course_id=Y&project_id=Z
            r.get do
              entities = Repository::PromptLogs.find_all(
                student_id: r.params['student_id'],
                course_id:  r.params['course_id'],
                project_id: r.params['project_id']
              )
              entities.map { |entity| Representer::PromptLog.new(entity).to_hash }
            end
          end
        end
      end
    end
  end
end
