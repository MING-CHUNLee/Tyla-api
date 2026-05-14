# frozen_string_literal: true

require 'fileutils'
require_relative 'require_app'
require_app

run Tyla::Api.freeze.app
