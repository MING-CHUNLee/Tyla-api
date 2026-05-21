# frozen_string_literal: true

module Tyla
  module Services
    TutorChatInput = Data.define(:course_id, :project_id, :student_id, :mode, :user_prompt, :history, :context_files) do
      def self.from(hash)
        ctx = hash[:context] || hash['context'] || {}
        context_files = ctx[:files] || ctx['files'] || []
        new(
          course_id:     hash[:course_id]   || hash['course_id'],
          project_id:    hash[:project_id]  || hash['project_id'],
          student_id:    hash[:student_id]  || hash['student_id'],
          mode:          hash[:mode]        || hash['mode'],
          user_prompt:   hash[:userPrompt]  || hash['userPrompt'],
          history:       hash[:history]     || hash['history'] || [],
          context_files: context_files
        )
      end
    end
  end
end
