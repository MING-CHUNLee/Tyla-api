# frozen_string_literal: true

ENV['RACK_ENV'] ||= 'test'

require 'minitest/autorun'
require 'minitest/spec'
require 'minitest/mock'

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

# Step 2 services — loaded after domain + infrastructure so constants are available.
# The database/ORM layer is intentionally excluded here; specs that need it
# (e.g. handle_tutor_chat_spec) set up their own in-memory DB.
require 'dry/monads'
%w[
  app/application/services/solution_loader.rb
  app/application/services/tutor_chat_result.rb
  app/application/services/tutor_chat_input.rb
  app/application/services/rate_limiter.rb
  app/application/services/policy_loader.rb
  app/application/services/guard_agent.rb
  app/application/services/tutor_orchestrator.rb
].each { |f| require File.join(ROOT, f) }
