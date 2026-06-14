# frozen_string_literal: true

module Tyla
  module Values
    # Structural loop-breaker for redundant load_file actions (plan 2026-06-13 §3/§4.1).
    # Drops any load_file whose path is ALREADY present in file_context (marked by a
    # `### <path>` header), and collapses intra-reply duplicates for the same path.
    #
    # Why structural, not just prompt steering: gpt-4o demonstrably ignores soft
    # constraints (see WorkspaceEditGate header comment). Once a file is loaded, no
    # further load_file for that path can ever be productive — making this gate
    # universally safe with no backward-compat risk.
    #
    # Activation: inert when file_context is blank or has no `### path` headers
    # (same convention as EditPatchContentGate, not WorkspaceEditGate — this gate
    # acts on already-loaded content, so its trigger is file_context, not workspace_overview).
    #
    # Ordering in apply_gates: MUST run BEFORE EditPatchContentGate. That gate
    # rewrites stale edit_file actions into load_file for already-loaded paths — which
    # are exactly the actions this gate would drop. Running after would defeat
    # content gate's stale-snapshot self-healing. Running before preserves it: we
    # drop only model-emitted redundant loads, then let the content gate produce
    # (legitimate) reloads as needed.
    #
    # Assumption (written here per §4.1): a `### path` header is treated as "file
    # fully loaded". If the frontend ever loads partial ranges, this gate would need
    # to check content completeness rather than header presence.
    #
    # Activation inconsistency note (§3): WorkspaceEditGate binds to workspace_overview;
    # this gate and EditPatchContentGate bind to file_context+header. Each is correct for
    # what it acts on. See §6 D7 and the cross-gate regression spec.
    module RedundantLoadGate
      LOAD_FILE = 'load_file'
      HEADER    = /^###[ \t]+(\S.*?)[ \t]*$/

      # Returns [gated_actions, dropped?]. `dropped?` is true iff at least one
      # load_file was removed (either redundant or intra-reply duplicate).
      def self.call(actions:, file_context:)
        return [actions, false] if blank?(file_context)

        loaded = loaded_paths(file_context)
        return [actions, false] if loaded.empty?

        seen  = Set.new
        gated = actions.reject { |action| redundant?(action, loaded, seen) }
        [gated, gated.size < actions.size]
      end

      # A load_file is redundant if its path is already loaded, or already seen
      # earlier in this same reply. First-seen unloaded paths are recorded in
      # `seen` so a second load_file for them (intra-reply duplicate) collapses.
      def self.redundant?(action, loaded, seen)
        return false unless action_type(action) == LOAD_FILE

        key = normalize(path_of(action))
        return true if loaded.include?(key) || seen.include?(key)

        seen << key
        false
      end
      private_class_method :redundant?

      def self.loaded_paths(file_context)
        file_context.to_s.lines.each_with_object(Set.new) do |line, set|
          m = line.match(HEADER)
          set << normalize(m[1]) if m
        end
      end
      private_class_method :loaded_paths

      def self.action_type(action) = action['type'] || action[:type]
      private_class_method :action_type

      def self.path_of(action) = action['path'] || action[:path]
      private_class_method :path_of

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
