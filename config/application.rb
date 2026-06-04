# frozen_string_literal: true

require 'roda'
require 'sequel'
require 'json'
require 'logger'

require_relative '../app/infrastructure/middleware/key_scrubber'

module Tyla
  class Api < Roda
    use Tyla::Middleware::KeyScrubber

    plugin :json
    plugin :json_parser
    plugin :halt
    plugin :all_verbs
    plugin :request_headers
    plugin :error_handler do |e|
      { error: e.message }
    end

    class << self
      attr_reader :db

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
