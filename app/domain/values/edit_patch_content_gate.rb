# frozen_string_literal: true

module Tyla
  module Values
    # Phase 2 (plan 2026-06-13 §4.4 / §8-6): backend early-warning content gate.
    # After WorkspaceEditGate confirms a path is loaded, this module checks that
    # each patch's `search` string actually matches the lines at `start_line` in
    # the file_context snapshot (CRLF-normalized). Mismatch → redirect to load_file
    # so the model gets fresh, re-numbered content next turn.
    #
    # Why this helps: if the student edited the file between the last load_file
    # round-trip and now, the backend's snapshot is stale. Catching that here
    # avoids a silent misapply on the frontend.
    #
    # Activation: inert when file_context is absent, has no "### path" headers,
    # or when the target path is not listed (WorkspaceEditGate already handles the
    # path-not-loaded case; this gate is the content layer on top). Old-contract
    # requests lack `start_line` so `content_mismatch?` naturally returns false.
    #
    # Sparse file_context: file_context may only carry a subset of a file's lines
    # (e.g. a budget-trimmed snippet). Lines not present in the snapshot are
    # silently skipped rather than treated as mismatches — the frontend's
    # validation (plan §5) remains the authoritative guard.
    module EditPatchContentGate
      EDIT_FILE = 'edit_file'
      LOAD_FILE = 'load_file'
      # "### path" header — same convention as WorkspaceEditGate::HEADER.
      HEADER = /^###[ \t]+(\S.*?)[ \t]*$/
      # "N| " or "  N| " line-number prefix as injected by the frontend.
      PREFIX = /\A[ \t]*(\d+)\|[ \t]?/

      # Returns [gated_actions, redirected?].
      def self.call(actions:, file_context:)
        return [actions, false] if blank?(file_context)

        line_map = parse_file_context(file_context)
        return [actions, false] if line_map.empty?

        apply(actions, line_map)
      end

      def self.apply(actions, line_map)
        emitted    = Set.new
        redirected = false
        gated = actions.flat_map do |action|
          keep, redirect = gate_action(action, line_map, emitted)
          redirected ||= redirect
          keep
        end
        [gated, redirected]
      end
      private_class_method :apply

      def self.gate_action(action, line_map, emitted)
        return [[action], false] unless action_type(action) == EDIT_FILE

        path    = normalize(path_of(action))
        file    = line_map[path]
        patches = patches_of(action)
        return [[action], false] if file.nil? || !patches.is_a?(Array) || patches.empty?
        return [[action], false] unless content_mismatch?(patches, file)

        load = emitted.add?(path) ? [load_file_for(action, path_of(action))] : []
        [load, true]
      end
      private_class_method :gate_action

      # Returns true iff at least one patch whose lines are fully present in the
      # snapshot shows a content mismatch. Patches with missing lines are skipped.
      def self.content_mismatch?(patches, file)
        patches.any? { |p| patch_mismatches?(p, file) }
      end
      private_class_method :content_mismatch?

      def self.patch_mismatches?(patch, file)
        start  = val(patch, 'start_line').to_i
        search = val(patch, 'search').to_s
        return false if start < 1 || search.empty?

        excerpt = excerpt_lines(file, start, search.lines.count)
        return false unless excerpt # incomplete snapshot → let frontend verify

        normalize_newlines(excerpt.join).chomp != normalize_newlines(search).chomp
      end
      private_class_method :patch_mismatches?

      # Looks up `key` (string) then `key.to_sym` in `hash`, supporting both
      # string-keyed and symbol-keyed action hashes emitted by the two parse paths.
      def self.val(hash, key)
        hash[key] || hash[key.to_sym]
      end
      private_class_method :val

      # Returns an Array of `count` content strings starting at 1-based `start`,
      # or nil if any requested line is absent from the snapshot.
      def self.excerpt_lines(file, start, count)
        lines = (start..start + count - 1).map { |n| file[n] }
        lines.none?(&:nil?) ? lines : nil
      end
      private_class_method :excerpt_lines

      # Builds { normalized_path => { line_number(int) => content_string } }.
      # The content string retains the original line ending so CRLF files can be
      # normalized at comparison time.
      def self.parse_file_context(file_context)
        current = nil
        file_context.to_s.lines.each_with_object({}) do |line, result|
          if (m = line.match(HEADER))
            current = normalize(m[1])
            result[current] ||= {}
          elsif current && (m = line.match(PREFIX))
            result[current][m[1].to_i] = line.sub(PREFIX, '')
          end
        end
      end
      private_class_method :parse_file_context

      def self.normalize_newlines(text)
        text.gsub("\r\n", "\n").gsub("\r", "\n")
      end
      private_class_method :normalize_newlines

      def self.load_file_for(action, path)
        if action.key?('type') || action.key?('path')
          { 'type' => LOAD_FILE, 'path' => path }
        else
          { type: LOAD_FILE, path: path }
        end
      end
      private_class_method :load_file_for

      def self.action_type(action) = action['type'] || action[:type]
      private_class_method :action_type

      def self.path_of(action) = action['path'] || action[:path]
      private_class_method :path_of

      def self.patches_of(action) = action['patches'] || action[:patches]
      private_class_method :patches_of

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
