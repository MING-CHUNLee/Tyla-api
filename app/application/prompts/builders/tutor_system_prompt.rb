# frozen_string_literal: true

module Tyla
  module Prompts
    # Pure composer: glues policy + solution + context-file blocks into one
    # system prompt string. Trimming (history truncation, student-file drop)
    # is the assembler's job, not this builder's.
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

      def self.format_file(file)
        path    = file[:path]    || file['path']
        content = file[:content] || file['content'] || ''
        "### #{path}\n```\n#{content}\n```"
      end
      private_class_method :format_file
    end
  end
end
