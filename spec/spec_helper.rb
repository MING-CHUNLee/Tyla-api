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
  Dir.glob(File.join(ROOT, pattern)).each { |f| require f }
end

# Step 2 services — loaded after domain + infrastructure so constants are available.
# The database/ORM layer is intentionally excluded here; specs that need it
# (e.g. run_tutor_chat_spec) set up their own in-memory DB.
require 'dry/monads'
%w[
  app/infrastructure/filesystem/tutor_chat/assignment_loader.rb
  app/infrastructure/filesystem/tutor_chat/solution_loader.rb
  app/infrastructure/filesystem/tutor_chat/student_file_loader.rb
  app/infrastructure/filesystem/tutor_chat/tutor_persona_resolver.rb
  app/application/services/guard/guard_agent.rb
].each { |f| require File.join(ROOT, f) }
