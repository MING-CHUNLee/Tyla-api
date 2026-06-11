# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

module Tyla
  module Response
    # `warnings` is optional (plan 2026-06-11 §2.7): backend trim notices such as
    # "file_context_dropped" / "history_truncated". nil when there are none.
    TutorChat = Data.define(:log_id, :status, :content, :actions, :usage, :warnings) do
      def initialize(warnings: nil, **rest)
        super(warnings: warnings, **rest)
      end
    end
  end

  module Representer
    class TutorChat < Roar::Decorator
      include Roar::JSON

      property :log_id
      property :status
      property :content
      property :actions          # NO render_nil → nil is OMITTED (never present on forbidden), [] renders as []
      property :usage, render_nil: true
      property :warnings         # NO render_nil → nil is OMITTED; builders set nil instead of [] so the field only appears non-empty
    end
  end
end
