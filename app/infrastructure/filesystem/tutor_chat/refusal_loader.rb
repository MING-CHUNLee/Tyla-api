# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      # Reads the "## Refusal Message" section out of the tutor's TUTOR.md.
      # Shares the source file with TutorPersonaLoader on purpose: per-tutor
      # refusal text lives next to per-tutor persona text, in one file.
      module RefusalLoader
        FIXTURE_PATH = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md',
          __dir__
        )

        HEADING = '## Refusal Message'

        def self.load(_project_id)
          content = File.read(FIXTURE_PATH)
          match   = content.match(/^#{Regexp.escape(HEADING)}\s*\n(.*?)(?=^##\s|\z)/m)
          raise Errno::ENOENT, "no '#{HEADING}' section in #{FIXTURE_PATH}" if match.nil?

          match[1].strip
        end
      end
    end
  end
end
