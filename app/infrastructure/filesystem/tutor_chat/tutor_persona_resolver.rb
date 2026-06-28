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
      # As of 2026-06-28 the per-persona capability profile (tool whitelist + the two
      # injection flags) is no longer a hardcoded Ruby table. Each persona declares it
      # in its own TUTOR.md YAML frontmatter (`tools` / `inject_workspace` /
      # `inject_reference`), and `persona_key` is now the persona's directory name
      # (e.g. `tutor-feynman`), read straight from disk — the old `FIXTURE_DIRS` /
      # `PROFILES` tables are gone.
      #
      # Pure function (testing plan §0.2): the `persona_key` is passed in; the ENV read
      # lives in a single seam in RunTutorChat. An unknown name RAISES (fail-closed,
      # §7.4): a typo or missing directory must crash loudly at deploy time, never
      # silently grant a fuller toolset. Missing frontmatter keys fail closed too —
      # absent `tools` → [], absent `inject_*` → false (least privilege).
      module TutorPersonaResolver
        Resolution = Data.define(:persona_text, :refusal, :profile)

        TUTORS_DIR = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/tutors', __dir__
        )

        # Leading YAML frontmatter block (between the first pair of `---` fences).
        FRONTMATTER = /\A---\s*\n(.*?)\n---\s*\n/m

        # Tolerate the deliberate "Example" suffix tier2/tier3 use (§6): for pure-dialogue
        # tutors the section is mainly a tone sample, but the guard-block path still reads
        # it verbatim, so the heading must match with OR without the suffix.
        REFUSAL_SECTION = /^## Refusal Message(?: Example)?\s*\n(.*?)(?=^##\s|\z)/m

        def self.call(persona_key)
          # Reject anything that is not a plain directory name (no path traversal): the
          # key indexes a single TUTOR.md under TUTORS_DIR, never an arbitrary path.
          raise KeyError, "invalid persona_key: #{persona_key.inspect}" unless persona_key.to_s.match?(/\A[\w-]+\z/)

          path = File.join(TUTORS_DIR, persona_key, 'TUTOR.md')
          raise KeyError, "unknown persona_key: #{persona_key.inspect}" unless File.file?(path)

          text = File.read(path)
          Resolution.new(
            persona_text: text,
            refusal:      extract_refusal(text, persona_key),
            profile:      build_profile(text, persona_key)
          )
        end

        # Build the PersonaProfile from the TUTOR.md frontmatter (2026-06-28). Only the
        # three capability keys are parsed (targeted, not a full YAML load) so the prose
        # `description` / `approach` fields stay free text and never need YAML-escaping
        # (some carry a "colon-space" that would otherwise break YAML.safe_load).
        def self.build_profile(text, persona_key)
          block = text[FRONTMATTER, 1]
          raise Errno::ENOENT, "no YAML frontmatter in #{persona_key}/TUTOR.md" if block.nil?

          Values::PersonaProfile.new(
            tools:            Values::TutorTools.named(parse_tools(block)),
            inject_workspace: parse_bool(block, 'inject_workspace'),
            inject_reference: parse_bool(block, 'inject_reference')
          )
        end

        # `tools: [load_file, load_reference]` → %w[load_file load_reference]. Absent or
        # empty → [] (fail-closed). An unknown tool name raises inside TutorTools.named
        # (loud at deploy — a typo must never silently drop or grant a tool).
        def self.parse_tools(block)
          match = block.match(/^tools:\s*\[(.*?)\]\s*$/m)
          return [] if match.nil?

          match[1].split(',').map(&:strip).reject(&:empty?)
        end

        # Only an explicit `true` grants the flag; anything else (absent, false, typo)
        # fails closed to false (least privilege, §7.4).
        def self.parse_bool(block, key)
          match = block.match(/^#{Regexp.escape(key)}:\s*(true|false)\b/)
          match ? match[1] == 'true' : false
        end

        def self.extract_refusal(text, persona_key)
          match = text.match(REFUSAL_SECTION)
          raise Errno::ENOENT, "no '## Refusal Message' section in #{persona_key}/TUTOR.md" if match.nil?

          match[1].strip
        end
      end
    end
  end
end
