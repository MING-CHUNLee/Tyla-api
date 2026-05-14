# frozen_string_literal: true

module Tyla
  class Api
    route do |r|
      r.on 'api' do
        r.on 'v1' do
          r.on 'prompt_logs' do
            # POST /api/v1/prompt_logs
            # Body matches the CLI guard-log shape:
            #   { course_id, project_id, student_id,
            #     userPrompt, probability: { attack, benign },
            #     reason, allowed, timestamp }
            r.post do
              contract = Request::CreatePromptLog.new
              result = contract.call(r.params)

              r.halt(422, { errors: result.errors.to_h }.to_json) unless result.success?

              d = result.to_h
              log = Database::PromptLogOrm.create(
                course_id:   d[:course_id],
                project_id:  d[:project_id],
                student_id:  d[:student_id],
                prompt:      d[:userPrompt],
                attack_prob: d[:probability][:attack],
                benign_prob: d[:probability][:benign],
                reason:      d[:reason],
                allowed:     d.fetch(:allowed, true)
              )
              response.status = 201
              serialize(log)
            end

            # GET /api/v1/prompt_logs?student_id=X&course_id=Y&project_id=Z
            r.get do
              dataset = Database::PromptLogOrm.order(Sequel.desc(:created_at))
              dataset = dataset.where(student_id: r.params['student_id']) if r.params['student_id']
              dataset = dataset.where(course_id:  r.params['course_id'])  if r.params['course_id']
              dataset = dataset.where(project_id: r.params['project_id']) if r.params['project_id']

              dataset.map { |log| serialize(log) }
            end
          end
        end
      end
    end

    private

    def serialize(log)
      {
        id:          log.id,
        course_id:   log.course_id,
        project_id:  log.project_id,
        student_id:  log.student_id,
        prompt:      log.prompt,
        attack_prob: log.attack_prob,
        benign_prob: log.benign_prob,
        reason:      log.reason,
        allowed:     log.allowed,
        created_at:  log.created_at
      }
    end
  end
end
