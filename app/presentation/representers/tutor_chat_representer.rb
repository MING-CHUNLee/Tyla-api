# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

module Tyla
  module Response
    TutorChat = Data.define(:log_id, :status, :content, :actions, :usage)
  end

  module Representer
    class TutorChat < Roar::Decorator
      include Roar::JSON

      property :log_id
      property :status
      property :content
      property :actions          # NO render_nil → nil is OMITTED (never present on forbidden), [] renders as []
      property :usage, render_nil: true
    end
  end
end
