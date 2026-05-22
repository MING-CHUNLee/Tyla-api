# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      module SolutionLoader
        # Phase 1: any project_id resolves to the CSDS-HW2 fixture. Phase 2 will
        # key by course_id+project_id and read from a production data root.
        FIXTURE_PATH = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/solutions/Hw2.Rmd',
          __dir__
        )

        def self.load(_project_id)
          File.read(FIXTURE_PATH)
        end

        # Retained for TutorOrchestrator, which predates the per-project loader.
        def self.load_stub
          ''
        end
      end
    end
  end
end
