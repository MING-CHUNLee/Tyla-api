# frozen_string_literal: true

require 'dry-validation'
require 'json'

module Tyla
  module Request
    class TutorChat < Dry::Validation::Contract
      MAX_HISTORY_BYTES = 500_000

      params do
        required(:course_id).filled(:string)
        required(:project_id).filled(:string)
        required(:student_id).filled(:string)
        required(:guard_log_id).filled(:integer)   # NEW — missing/wrong-type → bad_request (400)
        required(:prompt).filled(:string)
        optional(:history).array(:hash) do
          required(:role).filled(:string)
          required(:content).filled(:string)
        end
        # NEW — rich, un-compressed session turns (Option C). Backward-compatible with `history`.
        # Per-turn fields are validated here; the nested `actions` array is only checked as
        # array(:hash) — per-element normalization is deferred to Values::HistoryTurnSerializer.
        optional(:session_turns).array(:hash) do
          required(:prompt).filled(:string)         # the student's intent for that turn
          optional(:prose).maybe(:string)           # terminal assistant prose (empty for action-only turns)
          optional(:context_headers).maybe(:string) # headers-only block (### path lines, no contents)
          optional(:actions).array(:hash)           # terminal tutor actions (loose; normalized downstream)
        end
        optional(:file_context).filled(:string)        # live-workspace block: line-numbered LOADED file contents
        optional(:workspace_overview).filled(:string)   # NEW — frontend's file listing / scan summary (no contents)
      end

      rule(:history) do
        next unless value

        bytes = value.to_json.bytesize
        key.failure("exceeds #{MAX_HISTORY_BYTES} bytes") if bytes > MAX_HISTORY_BYTES
      end

      # session_turns shares the same 500 KB cap (Phase 0 §8-2): structurally smaller than `history`
      # since it carries headers-only path lines, not file contents.
      rule(:session_turns) do
        next unless value

        bytes = value.to_json.bytesize
        key.failure("exceeds #{MAX_HISTORY_BYTES} bytes") if bytes > MAX_HISTORY_BYTES
      end
    end
  end
end
