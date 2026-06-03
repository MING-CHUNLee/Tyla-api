# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

module Tyla
  module Response
    GuardCheck = Data.define(:log_id, :status, :refusal, :usage)
  end

  module Representer
    class GuardCheck < Roar::Decorator
      include Roar::JSON

      property :log_id
      property :status
      property :refusal, render_nil: true
      property :usage,   render_nil: true
    end
  end
end
