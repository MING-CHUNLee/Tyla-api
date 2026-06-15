# frozen_string_literal: true

module Tyla
  module Values
    # Deterministic, zero-LLM compression of a session turn into [{role, content}]
    # history pairs; omits file contents. Caps calibrated 2026-06-15 (plan §9).
    module HistoryTurnSerializer
      PROSE_CAP  = 600
      PATCH_CAP  = 400
      SCRIPT_CAP = 200
      PASTE_CAP  = 200

      PASTE_OMISSION = '[pasted code omitted; ask to re-share if needed]'
      FENCED_CODE_BLOCK = /```[^\n]*\n.*?```/m
      N_PIPE_BLOCK      = /(?:[ \t]*\d+\|[^\n]*\n)+/

      def self.call(turn)
        prompt = val(turn, 'prompt').to_s
        return [] if prompt.strip.empty?

        [build_user(turn, prompt), build_assistant(turn)]
      end

      def self.build_user(turn, prompt)
        seen_paths = FileContextHeader.paths(val(turn, 'context_headers')).to_a
        content    = strip_pasted_code(prompt)
        if seen_paths.any?
          content += "\n\n[Previously inspected last turn (contents not included now; " \
                     "call load_file to see them again): #{seen_paths.join(', ')}]"
        end
        { role: 'user', content: content }
      end
      private_class_method :build_user

      def self.build_assistant(turn)
        prose   = val(turn, 'prose').to_s
        lines   = prose.strip.empty? ? [] : [truncate(prose.strip, PROSE_CAP)]
        lines  += Array(val(turn, 'actions')).filter_map { |a| render_action(a) }
        content = lines.join("\n")
        content = '(No actionable reply.)' if content.strip.empty?
        { role: 'assistant', content: content }
      end
      private_class_method :build_assistant

      def self.val(hash, str_key)
        return nil unless hash.is_a?(Hash)

        hash.key?(str_key) ? hash[str_key] : hash[str_key.to_sym]
      end
      private_class_method :val

      def self.strip_pasted_code(text)
        return '' if text.nil? || text.empty?

        result = text.gsub(FENCED_CODE_BLOCK) { |b| b.length > PASTE_CAP ? PASTE_OMISSION : b }
        result.gsub(N_PIPE_BLOCK) { |b| b.length > PASTE_CAP ? "#{PASTE_OMISSION}\n" : b }
      end
      private_class_method :strip_pasted_code

      def self.truncate(text, cap)
        return text.to_s if text.nil? || text.length <= cap

        "#{text[0, cap]}…"
      end
      private_class_method :truncate

      def self.render_action(action)
        case val(action, 'type')
        when 'edit_file'      then render_edit(action)
        when 'execute_script' then render_script(action)
        when 'load_file'      then render_load(action)
        end
      end
      private_class_method :render_action

      def self.render_edit(action)
        path  = val(action, 'path').to_s
        lines = Array(val(action, 'patches')).filter_map { |p| render_patch(path, p) }
        lines.empty? ? nil : lines.join("\n")
      end
      private_class_method :render_edit

      def self.render_patch(path, patch)
        start_line  = val(patch, 'start_line')
        raw_search  = val(patch, 'search').to_s
        raw_replace = val(patch, 'replace').to_s
        "Suggested editing `#{path}` (line #{start_line}):#{patch_body(raw_search, raw_replace)}"
      end
      private_class_method :render_patch

      def self.patch_body(raw_search, raw_replace)
        search  = truncate(raw_search,  PATCH_CAP)
        replace = truncate(raw_replace, PATCH_CAP)
        if single_line?(raw_search) && single_line?(raw_replace)
          " \"#{search}\" → \"#{replace}\""
        else
          diff = search.lines.map { |l| "- #{l.chomp}" } +
                 replace.lines.map { |l| "+ #{l.chomp}" }
          "\n#{diff.join("\n")}"
        end
      end
      private_class_method :patch_body

      def self.single_line?(text) = !text.include?("\n")
      private_class_method :single_line?

      def self.render_script(action) = "Suggested a demo script: `#{truncate(val(action, 'code').to_s, SCRIPT_CAP)}`"
      private_class_method :render_script

      def self.render_load(action) = "Requested the contents of `#{val(action, 'path')}`."
      private_class_method :render_load
    end
  end
end
