# frozen_string_literal: true

module Tyla
  module Values
    # Server-side enforcement of the workspace edit contract (plan 2026-06-12
    # §2.2). A file is editable only when its line-numbered contents are actually
    # loaded into `file_context` — marked there by a `### <relative path>` header
    # (the CLI's existing "## File Contents" convention, now machine-read). An
    # `edit_file` whose path is NOT loaded is rewritten to a `load_file` for the
    # same path (patches dropped), so a fabricated edit costs one self-healing
    # round-trip instead of a silent no-op.
    #
    # Why structural, not just prompt steering: the `## Loading Workspace Files`
    # guide and the tightened tool descriptions are soft constraints, and gpt-4o
    # demonstrably ignores them — inventing a `N| ` prefix when the student pastes
    # code in chat. So the gate runs on the SHARED action path (after the
    # load_reference filter), covering both parse branches: native `tool_calls`
    # and the XML `<actions>` fallback.
    #
    # Activation (backward compatibility): the gate is inert unless the request
    # carries `workspace_overview` — the field doubles as the new-contract marker.
    # An old CLI that still sends the combined blob in `file_context` (no overview)
    # never trips it, so v1 `@`-mentioned edits behave exactly as before.
    module WorkspaceEditGate
      EDIT_FILE = 'edit_file'
      LOAD_FILE = 'load_file'

      # `### <path>` header line. Anchored to the start of a line so an inline
      # "### " inside file contents cannot register a phantom loaded path.
      HEADER = /^###[ \t]+(\S.*?)[ \t]*$/

      # Returns [gated_actions, redirected?]. `redirected?` is true iff at least
      # one edit_file was rewritten to (or collapsed into) a load_file.
      def self.call(actions:, file_context:, workspace_overview:)
        return [actions, false] if blank?(workspace_overview)

        loaded     = loaded_paths(file_context)
        pending    = load_targets(actions)
        redirected = false
        gated = actions.flat_map do |action|
          keep, redirect = gate_action(action, loaded, pending)
          redirected ||= redirect
          keep
        end
        [gated, redirected]
      end

      # Decide a single action's fate. Returns [actions_to_emit, redirected?].
      # Only an edit_file whose path is not loaded is rewritten — to one load_file
      # per still-unrequested missing path (duplicates collapse to nothing).
      def self.gate_action(action, loaded, pending)
        return [[action], false] unless action_type(action) == EDIT_FILE

        path = path_of(action)
        return [[action], false] if blank?(path) || loaded.include?(normalize(path))

        replacement = pending.add?(normalize(path)) ? [load_file_for(action, path)] : []
        [replacement, true]
      end
      private_class_method :gate_action

      # Paths already being loaded this turn — seeds dedup so a redirect never
      # duplicates an existing load_file (and two edits on one path collapse).
      def self.load_targets(actions)
        actions.each_with_object(Set.new) do |action, set|
          set << normalize(path_of(action)) if action_type(action) == LOAD_FILE
        end
      end
      private_class_method :load_targets

      # Mirror the original action's key style (string- vs symbol-keyed) so the
      # rewritten action serializes identically to a model-emitted one.
      def self.load_file_for(action, path)
        if action.key?('type') || action.key?('path')
          { 'type' => LOAD_FILE, 'path' => path }
        else
          { type: LOAD_FILE, path: path }
        end
      end
      private_class_method :load_file_for

      def self.loaded_paths(file_context)
        file_context.to_s.lines.each_with_object(Set.new) do |line, set|
          m = line.match(HEADER)
          set << normalize(m[1]) if m
        end
      end
      private_class_method :loaded_paths

      def self.action_type(action)
        action['type'] || action[:type]
      end
      private_class_method :action_type

      def self.path_of(action)
        action['path'] || action[:path]
      end
      private_class_method :path_of

      # Make header paths and action paths comparable: forward slashes, no
      # leading "./", trimmed. The frontend spells both the same way, but a
      # stray separator or prefix should not force a needless reload.
      def self.normalize(path)
        path.to_s.strip.tr('\\', '/').sub(%r{\A\./}, '')
      end
      private_class_method :normalize

      def self.blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
      private_class_method :blank?
    end
  end
end
