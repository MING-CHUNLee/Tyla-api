# frozen_string_literal: true

module Tyla
  class Api
    # Map service-level failure tags to the symbol the Response::Result
    # envelope expects. Keep this table in one place so route handlers do
    # not pattern-match raw tags inline.
    SERVICE_FAILURE_STATUS = {
      bad_request: :bad_request,
      unauthorized: :unauthorized,
      forbidden: :forbidden,
      not_found: :not_found,
      context_overflow: :payload_too_large,   # pre-flight estimate (prompt assembler)
      input_too_large: :payload_too_large,    # (plan 2026-06-24 route D) — provider-real 413
      cannot_process: :cannot_process,
      upstream_error: :upstream_error,
      upstream_timeout: :upstream_timeout,
      rate_limited: :too_many_requests,   # (plan 2026-06-18 route C1) — provider 429
      db_error: :internal_error
    }.freeze

    route do |r|
      r.on 'api' do
        r.on 'v1' do
          r.on 'tutor_chats' do
            # POST /api/v1/tutor_chats
            # Accepts { course_id, project_id, student_id, guard_log_id, prompt,
            # history?, file_context? } + X-LLM-Key header. Verifies guard_log_id
            # against the DB (no LLM call) — the referenced /guard_checks row must
            # exist, match this prompt, and not be forbidden — then composes the
            # tutor system prompt from on-disk artefacts plus the optional live
            # file_context and forwards to the tutor LLM. Returns the LLM reply
            # (with parsed actions[]) or a Socratic refusal.
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
                # (C1) echo the provider's back-off as a Retry-After header so the
                # frontend can wait without parsing the body; errors.retry_after stays
                # as the JSON fallback. Only set when present.
                if tag == :rate_limited && errors.is_a?(Hash) && errors[:retry_after]
                  response['Retry-After'] = errors[:retry_after].to_s
                end
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
            # Runs GuardAgent server-side, persists result, and returns the unified
            # status enum (done / forbidden / unavailable) with guard-judge usage.
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

              kind, dto = outcome.value!
              response.status = kind == :unavailable ? 202 : 200
              Representer::GuardCheck.new(dto).to_hash
            end
          end

          r.on 'prompt_logs' do
            # Read-only route. Prompt-log *writes* now happen server-side inside
            # /guard_checks (RunGuardCheck) and /tutor_chats (RunTutorChat). The
            # old POST handler (CreatePromptLog) accepted client-side guard logs
            # and was retired once the guard moved server-side — no client posts
            # here anymore.
            #
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
