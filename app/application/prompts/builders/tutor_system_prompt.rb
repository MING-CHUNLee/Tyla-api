# frozen_string_literal: true

module Tyla
  module Prompts
    module TutorSystemPrompt
      def self.build(policy_text:, solution_text:, context_files:)
        parts = [policy_text]
        parts << "## Reference Solution\n#{solution_text}" unless solution_text.nil? || solution_text.empty?

        unless context_files.nil? || context_files.empty?
          file_block = context_files.map { |f| format_file(f) }.join("\n\n")
          parts << "## Student Workspace Files\n#{file_block}"
        end

        parts.join("\n\n---\n\n")
      end

      def self.truncate_history(history)
        return [] if history.nil?

        max_messages = Values::PayloadLimits::MAX_HISTORY_TURNS * 2
        history.last(max_messages)
      end

      def self.format_file(file)
        path    = file[:path] || file['path']
        content = file[:content] || file['content'] || ''
        lines = content.lines
        limit = Values::PayloadLimits::MAX_FILE_LINES
        body  = lines.first(limit).join
        body += "\n# ... (truncated, showing first #{limit} lines)\n" if lines.size > limit
        "### #{path}\n```\n#{body}\n```"
      end
      private_class_method :format_file
    end
  end
end
