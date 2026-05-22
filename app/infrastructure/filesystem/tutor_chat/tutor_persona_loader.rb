# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      # Single-persona variant for the /tutor_chats endpoint. The legacy
      # PolicyLoader (mode-keyed, used by HandleTutorChat) is unchanged.
      module TutorPersonaLoader
        FIXTURE_PATH = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md',
          __dir__
        )

        def self.load(_project_id)
          File.read(FIXTURE_PATH)
        end
      end
    end
  end
end
