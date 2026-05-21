# frozen_string_literal: true

require 'dry/monads'
require 'dry/monads/do'

module Tyla
  module Services
    class HandleTutorChat
      include Dry::Monads[:result]
      include Dry::Monads::Do

      # Shared rate limiter across all instances; overridable for testing.
      def self.shared_rate_limiter
        @shared_rate_limiter ||= RateLimiter.new
      end

      def initialize(rate_limiter: nil)
        @rate_limiter = rate_limiter
      end

      def call(request_data, headers)
        provider = headers['X-LLM-Provider'] or return Failure[:unauthorized, 'missing X-LLM-Provider']
        api_key  = headers['X-LLM-Key']      or return Failure[:unauthorized, 'missing X-LLM-Key']

        request      = TutorChatInput.from(request_data)
        rate_limiter = @rate_limiter || self.class.shared_rate_limiter
        yield rate_limiter.check!(request.student_id)

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        pending = Entity::PromptLog.new(
          id:                 nil,
          course_id:          request.course_id,
          project_id:         request.project_id,
          student_id:         request.student_id,
          prompt:             request.user_prompt,
          attack_probability: nil,
          evaluation:         nil,
          created_at:         nil
        )
        log = Repository::PromptLogs.create(pending)

        llm    = Infrastructure::LlmClient.for(provider: provider, api_key: api_key)
        guard  = GuardAgent.new(llm_client: llm)
        policy = PolicyLoader.new
        orch   = TutorOrchestrator.new(llm_client: llm, guard: guard, policy_loader: policy)

        result = yield orch.call(request)

        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

        Repository::PromptLogs.update(
          log.id,
          attack_probability: result.probability&.fetch(:attack),
          evaluation:         result.reason
        )

        emit_structured_log(request: request, result: result, latency_ms: latency_ms)

        Success({ result: result, log_id: log.id })
      rescue Sequel::Error
        Failure[:db_error, 'could not write log entry']
      end

      private

      def emit_structured_log(request:, result:, latency_ms:)
        entry = {
          time:          Time.now.utc.iso8601(3),
          student_id:    request.student_id,
          course_id:     request.course_id,
          mode:          request.mode,
          attack_prob:   result.probability&.fetch(:attack),
          guard_allowed: result.allowed?,
          latency_ms:    latency_ms,
          input_tokens:  result.usage&.fetch(:input_tokens),
          output_tokens: result.usage&.fetch(:output_tokens),
          status:        result.status
        }.compact
        $stdout.puts entry.to_json
      end
    end
  end
end
