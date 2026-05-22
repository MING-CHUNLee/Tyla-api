# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      # Phase 1: any project_id resolves to the CSDS-HW2 fixture. Phase 2 will
      # key by course_id+project_id and read from a production data root.
      module AssignmentLoader
        FIXTURE_PATH = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/assignment/HW 02.docx.txt',
          __dir__
        )

        def self.load(_project_id)
          File.read(FIXTURE_PATH)
        end
      end
    end
  end
end
