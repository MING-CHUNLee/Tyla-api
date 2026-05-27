# frozen_string_literal: true

module Tyla
  class Api
    # Map service-level failure tags to the symbol the Response::Result
    # envelope expects. Keep this table in one place so route handlers do
    # not pattern-match raw tags inline.
    SERVICE_FAILURE_STATUS = {
      bad_request:      :bad_request,
      unauthorized:     :unauthorized,
      forbidden:        :forbidden,
      not_found:        :not_found,
      cannot_process:   :cannot_process,
      upstream_error:   :upstream_error,
      upstream_timeout: :upstream_timeout,
      db_error:         :internal_error
    }.freeze

    route do |r|
      r.on 'api' do
        r.on 'v1' do
          r.on 'tutor_chats' do
            # POST /api/v1/tutor_chats
            # Accepts { course_id, project_id, student_id, prompt, history? } +
            # X-LLM-Key header. Re-runs the guard server-side (defence in
            # depth), composes the tutor system prompt from on-disk artefacts,
            # and forwards to the tutor LLM. Returns the LLM reply or a refusal.
            r.post do
              outcome = Services::RunTutorChat.new.call(r.params, request.env)

              if outcome.failure?
                tag, message, errors = outcome.failure
                result = Response::Result.new(
                  status:  SERVICE_FAILURE_STATUS.fetch(tag, :internal_error),
                  message: message,
                  errors:  errors
                )
                rep = Representer::HttpResponse.new(result)
                r.halt(rep.http_status_code, rep.to_json)
              end

              kind, dto = outcome.value!
              response.status = kind == :unavailable ? 202 : 200
              Representer::TutorChat.new(dto).to_hash
            end
          end

          r.on 'guard_checks' do
            # POST /api/v1/guard_checks
            # Accepts { course_id, project_id, student_id, prompt } + X-LLM-Key header.
            # Runs GuardAgent server-side, persists result, returns allowed/blocked decision.
            r.post do
              outcome = Services::RunGuardCheck.new.call(r.params, request.env)

              if outcome.failure?
                tag, message, errors = outcome.failure
                result = Response::Result.new(
                  status:  SERVICE_FAILURE_STATUS.fetch(tag, :internal_error),
                  message: message,
                  errors:  errors
                )
                rep = Representer::HttpResponse.new(result)
                r.halt(rep.http_status_code, rep.to_json)
              end

              kind, payload = outcome.value!
              response.status = kind == :llm_unavailable ? 202 : 200
              payload
            end
          end

          r.on 'prompt_logs' do
            # POST /api/v1/prompt_logs
            # Accepts the CLI guard-log payload; see
            # Request::CreatePromptLog for the validated input shape.
            r.post do
              outcome = Services::CreatePromptLog.new.call(r.params)

              if outcome.failure?
                tag, message, errors = outcome.failure
                result = Response::Result.new(
                  status:  SERVICE_FAILURE_STATUS.fetch(tag, :internal_error),
                  message: message,
                  errors:  errors
                )
                rep = Representer::HttpResponse.new(result)
                r.halt(rep.http_status_code, rep.to_json)
              end

              response.status = Representer::HttpResponse::HTTP_CODE.fetch(:created)
              Representer::PromptLog.new(outcome.value!).to_hash
            end

            # GET /api/v1/prompt_logs?student_id=X&course_id=Y&project_id=Z
            r.get do
              outcome = Services::ListPromptLogs.new.call(r.params)

              if outcome.failure?
                tag, message = outcome.failure
                result = Response::Result.new(
                  status:  SERVICE_FAILURE_STATUS.fetch(tag, :internal_error),
                  message: message
                )
                rep = Representer::HttpResponse.new(result)
                r.halt(rep.http_status_code, rep.to_json)
              end

              response.status = Representer::HttpResponse::HTTP_CODE.fetch(:ok)
              outcome.value!.map { |entity| Representer::PromptLog.new(entity).to_hash }
            end
          end
        end
      end
    end
  end
end
