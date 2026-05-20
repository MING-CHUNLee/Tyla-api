# frozen_string_literal: true

ENV['RACK_ENV'] ||= 'test'

require 'minitest/autorun'
require 'minitest/spec'

# Load only the application code Step 1 needs.
# We deliberately skip the database/ORM and route layers so specs do not
# require a migrated DB. Higher-step specs that need those layers can
# require them on their own.
ROOT = File.expand_path('..', __dir__)

%w[
  app/domain/**/*.rb
  app/infrastructure/llm/**/*.rb
  app/infrastructure/middleware/**/*.rb
  app/application/prompts/**/*.rb
].each do |pattern|
  Dir.glob(File.join(ROOT, pattern)).sort.each { |f| require f }
end
