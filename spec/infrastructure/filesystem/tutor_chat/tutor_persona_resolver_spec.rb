# frozen_string_literal: true

require_relative '../../../spec_helper'

# Domain values must load before the resolver — its PROFILES table is built at
# require time from TutorTools.named / PersonaProfile.new.
%w[
  app/domain/values/tutor_tools.rb
  app/domain/values/persona_profile.rb
  app/infrastructure/filesystem/tutor_chat/tutor_persona_resolver.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Infrastructure
    module Filesystem
      describe TutorPersonaResolver do
        it 'tier1 resolves the solver persona, its same-file refusal, and the full toolset' do
          res = TutorPersonaResolver.call('tier1')

          _(res.persona_text).must_include 'Tutor-Solver Mode'
          _(res.refusal).must_include 'build and verify working code'
          _(res.profile.tool_names).must_equal %w[load_file edit_file execute_script load_reference]
          _(res.profile.inject_workspace).must_equal true
          _(res.profile.inject_reference).must_equal true
        end

        it 'tier2 resolves the feynman persona with a read-only toolset (no edit/execute)' do
          res = TutorPersonaResolver.call('tier2')

          _(res.persona_text).must_include 'name: tutor-feynman'
          _(res.profile.tool_names).must_equal %w[load_file load_reference]
          _(res.refusal).wont_be_empty                       # tolerates the "Example" heading suffix
        end

        it 'tier3 resolves the socratic persona with NO tools and no injection' do
          res = TutorPersonaResolver.call('tier3')

          _(res.persona_text).must_include 'name: tutor-socratic'
          _(res.profile.tools).must_equal []
          _(res.profile.tool_names).must_equal []
          _(res.profile.inject_workspace).must_equal false
          _(res.profile.inject_reference).must_equal false
          _(res.refusal).wont_be_empty                       # tolerates the "Example" heading suffix
        end

        it 'an unknown key raises (fail-closed, §7.4) — never silently grants tier1' do
          _ { TutorPersonaResolver.call('full-agentic') }.must_raise KeyError
        end
      end
    end
  end
end
