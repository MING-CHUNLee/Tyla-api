# frozen_string_literal: true

require_relative '../../../spec_helper'

# Domain values must load before the resolver — it resolves each persona's profile
# at call time via TutorTools.named / PersonaProfile.new (parsed from frontmatter).
%w[
  app/domain/values/tutor_tools.rb
  app/domain/values/persona_profile.rb
  app/infrastructure/filesystem/tutor_chat/tutor_persona_resolver.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Infrastructure
    module Filesystem
      describe TutorPersonaResolver do
        it 'tutor-solver resolves the solver persona, its same-file refusal, and the full toolset' do
          res = TutorPersonaResolver.call('tutor-solver')

          _(res.persona_text).must_include 'Tutor-Solver Mode'
          _(res.refusal).must_include 'build and verify working code'
          _(res.profile.tool_names).must_equal %w[load_file edit_file execute_script load_reference]
          _(res.profile.inject_workspace).must_equal true
          _(res.profile.inject_reference).must_equal true
        end

        it 'tutor-feynman resolves the feynman persona with a read-only toolset (no edit/execute)' do
          res = TutorPersonaResolver.call('tutor-feynman')

          _(res.persona_text).must_include 'name: tutor-feynman'
          _(res.profile.tool_names).must_equal %w[load_file load_reference]
          _(res.profile.inject_workspace).must_equal true
          _(res.profile.inject_reference).must_equal true
          _(res.refusal).wont_be_empty                       # tolerates the "Example" heading suffix
        end

        it 'tutor-socratic resolves the socratic persona with NO tools and no injection' do
          res = TutorPersonaResolver.call('tutor-socratic')

          _(res.persona_text).must_include 'name: tutor-socratic'
          _(res.profile.tools).must_equal []
          _(res.profile.tool_names).must_equal []
          _(res.profile.inject_workspace).must_equal false
          _(res.profile.inject_reference).must_equal false
          _(res.refusal).wont_be_empty                       # tolerates the "Example" heading suffix
        end

        it 'an unknown persona name raises (fail-closed, §7.4) — never silently grants a fuller toolset' do
          _ { TutorPersonaResolver.call('full-agentic') }.must_raise KeyError
        end

        it 'raises Errno::ENOENT when the TUTOR.md has no YAML frontmatter (fail-closed §7.4)' do
          File.stub(:file?, ->(*) { true }) do
            File.stub(:read, "# Body only — no frontmatter fences\n\n## Refusal Message\nStop.\n") do
              _ { TutorPersonaResolver.call('tutor-nofm') }.must_raise Errno::ENOENT
            end
          end
        end

        it 'raises Errno::ENOENT when the TUTOR.md has no Refusal Message section (fail-closed §7.4)' do
          no_refusal = "---\nname: tutor-nore\ntools: []\ninject_workspace: false\ninject_reference: false\n---\n\n# Body without refusal section\n"
          File.stub(:file?, ->(*) { true }) do
            File.stub(:read, no_refusal) do
              _ { TutorPersonaResolver.call('tutor-nore') }.must_raise Errno::ENOENT
            end
          end
        end
      end
    end
  end
end
