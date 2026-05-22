# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      # Phase 1: any project_id resolves to the CSDS-HW2 fixture student file.
      # Phase 2 will accept the student's WIP file in the request body.
      module StudentFileLoader
        FIXTURE_PATH = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/student-files/Hw2.Rmd',
          __dir__
        )
        FILENAME = 'Hw2.Rmd'

        def self.load(_project_id)
          File.read(FIXTURE_PATH)
        end
      end
    end
  end
end
