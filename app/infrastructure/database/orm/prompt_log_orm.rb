# frozen_string_literal: true

require 'sequel'

module Tyla
  module Database
    class PromptLogOrm < Sequel::Model(:prompt_logs)
      plugin :timestamps, update_on_create: true
    end
  end
end
