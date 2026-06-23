# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      # Single resolver that replaces the two hardcoded loaders (TutorPersonaLoader +
      # RefusalLoader), each of which independently hardcoded the `tutor-guide` path
      # and ignored project_id. MS3 plan §7.1.1: a persona's full text, its same-file
      # `## Refusal Message` section, and its capability profile must come from ONE
      # source — otherwise a socratic persona could end up emitting a solver refusal.
      #
      # Pure function (testing plan §0.2): the `persona_key` is passed in; the ENV read
      # lives in a single seam in RunTutorChat. An unknown key RAISES (fail-closed,
      # §7.4): a typo or missing config must crash loudly at deploy time, never
      # silently grant tier1's full toolset.
      module TutorPersonaResolver
        Resolution = Data.define(:persona_text, :refusal, :profile)

        TUTORS_DIR = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/tutors', __dir__
        )

        # persona_key → fixtures directory (which TUTOR.md to read). §7.1.
        FIXTURE_DIRS = {
          'tier1' => 'tutor-solver',
          'tier2' => 'tutor-feynman',
          'tier3' => 'tutor-socratic'
        }.freeze

        # persona_key → PersonaProfile (tool whitelist + injection flags). §7.1 table.
        PROFILES = {
          'tier1' => Values::PersonaProfile.new(
            tools:            Values::TutorTools.named(%w[load_file edit_file execute_script load_reference]),
            inject_workspace: true,
            inject_reference: true
          ),
          'tier2' => Values::PersonaProfile.new(
            tools:            Values::TutorTools.named(%w[load_file load_reference]),
            inject_workspace: true,
            inject_reference: true
          ),
          'tier3' => Values::PersonaProfile.new(
            tools:            [],
            inject_workspace: false,
            inject_reference: false
          )
        }.freeze

        # Tolerate the deliberate "Example" suffix tier2/tier3 use (§6): for pure-dialogue
        # tutors the section is mainly a tone sample, but the guard-block path still reads
        # it verbatim, so the heading must match with OR without the suffix.
        REFUSAL_SECTION = /^## Refusal Message(?: Example)?\s*\n(.*?)(?=^##\s|\z)/m

        def self.call(persona_key)
          raise KeyError, "unknown persona_key: #{persona_key.inspect}" unless FIXTURE_DIRS.key?(persona_key)

          dir  = FIXTURE_DIRS.fetch(persona_key)
          text = File.read(File.join(TUTORS_DIR, dir, 'TUTOR.md'))
          Resolution.new(
            persona_text: text,
            refusal:      extract_refusal(text, dir),
            profile:      PROFILES.fetch(persona_key)
          )
        end

        def self.extract_refusal(text, dir)
          match = text.match(REFUSAL_SECTION)
          raise Errno::ENOENT, "no '## Refusal Message' section in #{dir}/TUTOR.md" if match.nil?

          match[1].strip
        end
      end
    end
  end
end
