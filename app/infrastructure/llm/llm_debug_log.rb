# frozen_string_literal: true

require 'json'
require 'fileutils'

module Tyla
  module Infrastructure
    # Appends every request/response round-trip between the backend and an LLM
    # provider to a debug log, so each turn's exact wire payload can be inspected.
    #
    # Opt-in and otherwise zero-cost: it does nothing unless LLM_DEBUG_LOG is set,
    # so test runs and production traffic are never written unless explicitly
    # enabled. Set the variable to:
    #   - "1" / "true" / "on"  → write to the default path (log/llm_debug.log)
    #   - any other non-blank   → treat the value as the log file path
    #   - unset / "" / "0" / "false" / "off" → disabled
    #
    # A logging failure (unwritable path, etc.) must never break an LLM call, so
    # every public method swallows its own errors.
    module LlmDebugLog
      DEFAULT_PATH = 'log/llm_debug.log'
      # Defensive: the request body carries no API key (the key rides in headers,
      # which we never log) — but scrub any sk-… token from logged content anyway.
      KEY_PATTERN  = /sk-[A-Za-z0-9_\-]+/
      REDACTION    = '[REDACTED]'

      # Per-round-trip handle returned by .request and handed back to .response so
      # the two halves can be correlated and the latency measured.
      Trace = Struct.new(:id, :provider, :started_at)

      MUTEX = Mutex.new
      @counter = 0

      module_function

      def enabled?
        !path.nil?
      end

      # Resolves the configured log destination, or nil when logging is disabled.
      def path
        flag = ENV['LLM_DEBUG_LOG'].to_s.strip
        return nil if flag.empty? || %w[0 false off].include?(flag.downcase)

        %w[1 true on].include?(flag.downcase) ? DEFAULT_PATH : flag
      end

      # Logs an outgoing request. `body` is the JSON string about to be POSTed.
      # Returns a Trace (or nil when disabled) to pass to .response.
      def request(provider:, model:, endpoint:, body:)
        return nil unless enabled?

        trace = Trace.new(next_id, provider, monotonic)
        write <<~ENTRY
          #{separator}
          [#{timestamp}] ##{trace.id} #{provider} → REQUEST  model=#{model}
          endpoint=#{endpoint}
          #{divider}
          #{pretty(body)}
        ENTRY
        trace
      rescue StandardError
        nil
      end

      # Logs the matching response. No-op when `trace` is nil (logging disabled or
      # the request half failed). `body` is the raw response body string. `headers`
      # (optional) is the response header hash — logged so C3 can measure the
      # provider's real `*ratelimit*` field names; defaults to {} (no header block,
      # preserving the original output for callers that don't pass it).
      def response(trace, status:, body:, headers: {})
        return unless trace

        header_block = headers.empty? ? '' : "headers=#{headers.inspect}\n#{divider}\n"
        write <<~ENTRY
          [#{timestamp}] ##{trace.id} #{trace.provider} ← RESPONSE status=#{status} (#{elapsed_ms(trace)}ms)
          #{divider}
          #{header_block}#{pretty(body)}
        ENTRY
        nil
      rescue StandardError
        nil
      end

      # Logs a round-trip that never produced a response (e.g. a timeout).
      def failure(trace, error:)
        return unless trace

        write "[#{timestamp}] ##{trace.id} #{trace.provider} ✗ NO RESPONSE (#{elapsed_ms(trace)}ms): #{error}\n"
        nil
      rescue StandardError
        nil
      end

      # ── internals ──────────────────────────────────────────────────────────────

      def next_id
        MUTEX.synchronize { @counter += 1 }
      end

      def write(text)
        target = path
        MUTEX.synchronize do
          FileUtils.mkdir_p(File.dirname(target))
          File.open(target, 'a') { |f| f.write(scrub(text)) }
        end
      end

      # Pretty-print JSON bodies for readability; fall back to the raw string when
      # the payload is not valid JSON (e.g. an upstream error page).
      def pretty(body)
        JSON.pretty_generate(JSON.parse(body.to_s))
      rescue JSON::ParserError
        body.to_s
      end

      def scrub(text)
        text.gsub(KEY_PATTERN, REDACTION)
      end

      def elapsed_ms(trace)
        ((monotonic - trace.started_at) * 1000).round
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def timestamp
        Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')
      end

      def separator
        '=' * 80
      end

      def divider
        '-' * 80
      end
    end
  end
end
