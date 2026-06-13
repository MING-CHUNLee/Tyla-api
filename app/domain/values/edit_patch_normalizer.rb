# frozen_string_literal: true

module Tyla
  module Values
    # Defensive wire-format hygiene for edit_file patches (plan 2026-06-13 §4.3).
    #
    # The line-number contract moved the file line number OUT of the `search`
    # string and into a required `start_line` integer, so `search`/`replace` are
    # now meant to be plain code. But a model trained on the old "copy the N| "
    # prefix" contract may still paste the `N| ` display prefix into either
    # string. This normalizer strips a leading `<digits>| ` from every line of
    # every edit_file patch's `search`/`replace`, guaranteeing the actions that
    # reach the client carry plain content the frontend can match against the
    # real (unprefixed) file.
    #
    # It is hygiene ONLY: it does not compare `search` against the file and does
    # not touch `start_line` (plan §4.3/§4.4 — the frontend, holding the live
    # file, is the authoritative content gate; the backend re-validating is
    # redundant). Runs on the SHARED action path so both parse branches (native
    # `tool_calls`, XML `<actions>` fallback) are covered, mirroring
    # WorkspaceEditGate. Non-edit_file actions pass through untouched.
    module EditPatchNormalizer
      EDIT_FILE = 'edit_file'

      PATCH_FIELDS = %w[search replace].freeze

      # Leading `N| ` display prefix on a single line: optional indent, one or
      # more digits, a pipe, then an optional single space. Anchored to the start
      # of the line (per-line application below), so a pipe in the middle of code
      # is never mistaken for a prefix.
      PREFIX = /\A[ \t]*\d+\|[ \t]?/

      # Returns a new actions array with every edit_file patch's search/replace
      # stripped of N| prefixes. Other actions are returned unchanged.
      def self.call(actions)
        actions.map { |action| normalize_action(action) }
      end

      def self.normalize_action(action)
        return action unless action_type(action) == EDIT_FILE

        patches = action['patches'] || action[:patches]
        return action unless patches.is_a?(Array)

        patches_key = action.key?('patches') ? 'patches' : :patches
        action.merge(patches_key => patches.map { |patch| normalize_patch(patch) })
      end
      private_class_method :normalize_action

      def self.normalize_patch(patch)
        return patch unless patch.is_a?(Hash)

        patch.each_with_object(patch.dup) do |(key, value), out|
          out[key] = strip_prefixes(value) if PATCH_FIELDS.include?(key.to_s)
        end
      end
      private_class_method :normalize_patch

      # Strip the prefix per line so multi-line search/replace are cleaned whole.
      # String#lines keeps each line's terminator (incl. a trailing \r on CRLF
      # files), so join restores the original line endings minus the prefixes.
      def self.strip_prefixes(text)
        return text unless text.is_a?(String)

        text.lines.map { |line| line.sub(PREFIX, '') }.join
      end
      private_class_method :strip_prefixes

      def self.action_type(action)
        action['type'] || action[:type]
      end
      private_class_method :action_type
    end
  end
end
