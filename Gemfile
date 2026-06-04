# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.3.10'

# Web framework & server
gem 'puma', '~> 6.0'
gem 'rack-ssl-enforcer'
gem 'roda', '~> 3.0'
gem 'tilt'

# Database
gem 'sequel',         '~> 5.0'
gem 'sqlite3',        '>= 1.0'   # dev / test

group :production do
  gem 'pg', '~> 1.0'   # production PostgreSQL
end

# Validation & types
gem 'dry-monads',     '~> 1.6'
gem 'dry-operation',  '~> 1.0'
gem 'dry-struct',     '~> 1.6'
gem 'dry-validation', '~> 1.10'

# Serialisation
gem 'multi_json'
gem 'roar', '~> 1.2'

# Auth & crypto
gem 'google-id-token'
gem 'rbnacl'

# AWS
gem 'aws-sdk-s3',     '~> 1.0'

# Config & process management
gem 'figaro',         '~> 1.2'
gem 'foreman',        '~> 0.0'

# Pin bigdecimal to 3.x — dry-types 1.7.2 requires bigdecimal (~> 3.0)
gem 'bigdecimal', '~> 3.1'

# Utilities
gem 'csv'
gem 'json_schemer'
gem 'logger'
gem 'ostruct'
gem 'rexml'
gem 'table_print', '~> 1.0'

# Development & test
gem 'bundler-audit'
gem 'minitest',       '~> 6.0'
gem 'minitest-mock',  '~> 5.27'
gem 'pry'
gem 'rack-test'
gem 'rake', '~> 13.0'
gem 'rubocop'
gem 'simplecov'
gem 'webmock', '~> 3.0'
