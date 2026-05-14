# frozen_string_literal: true

require 'roda'
require 'sequel'
require 'json'
require 'logger'

module Tyla
  class Api < Roda
    plugin :json
    plugin :json_parser
    plugin :halt
    plugin :all_verbs
    plugin :request_headers
    plugin :error_handler do |e|
      { error: e.message }
    end

    class << self
      def db
        @db
      end

      def db=(connection)
        @db = connection
        Sequel::Model.db = connection
      end

      def environment
        (ENV['RACK_ENV'] || 'development').to_sym
      end
    end
  end
end
