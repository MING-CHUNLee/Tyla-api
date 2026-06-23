# frozen_string_literal: true

require_relative '../../../spec_helper'

%w[
  app/infrastructure/filesystem/tutor_chat/assignment_loader.rb
  app/infrastructure/filesystem/tutor_chat/solution_loader.rb
  app/infrastructure/filesystem/tutor_chat/student_file_loader.rb
].each { |f| require File.join(ROOT, f) }

module Tyla
  module Infrastructure
    module Filesystem
      describe 'tutor_chat loaders (Phase 1 fixture)' do
        it 'AssignmentLoader reads the HW 02 assignment fixture' do
          text = AssignmentLoader.load('HW2')
          _(text).wont_be_empty
        end

        it 'SolutionLoader reads the Hw2.Rmd reference solution' do
          text = SolutionLoader.load('HW2')
          _(text).wont_be_empty
        end

        it 'StudentFileLoader reads the student Hw2.Rmd fixture' do
          text = StudentFileLoader.load('HW2')
          _(text).wont_be_empty
          _(StudentFileLoader::FILENAME).must_equal 'Hw2.Rmd'
        end

        # NOTE: persona + refusal loading moved to TutorPersonaResolver (MS3 §7.1.1);
        # see tutor_persona_resolver_spec.rb. The two single-file loaders are retired.

        it 'the remaining loaders ignore project_id in Phase 1' do
          _(AssignmentLoader.load('anything')).wont_be_empty
          _(SolutionLoader.load('anything')).wont_be_empty
          _(StudentFileLoader.load('anything')).wont_be_empty
        end
      end
    end
  end
end
