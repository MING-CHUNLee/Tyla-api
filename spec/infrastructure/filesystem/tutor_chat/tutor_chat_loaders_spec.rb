# frozen_string_literal: true

require_relative '../../../spec_helper'

%w[
  app/infrastructure/filesystem/tutor_chat/assignment_loader.rb
  app/infrastructure/filesystem/tutor_chat/solution_loader.rb
  app/infrastructure/filesystem/tutor_chat/student_file_loader.rb
  app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb
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

        it 'TutorPersonaLoader reads the tutor-guide TUTOR.md fixture' do
          text = TutorPersonaLoader.load('HW2')
          _(text).must_include 'Tutor-Guide Mode'
        end

        it 'SolutionLoader still answers .load_stub for the legacy orchestrator' do
          _(SolutionLoader.load_stub).must_equal ''
        end

        it 'all four loaders ignore project_id in Phase 1' do
          _(AssignmentLoader.load('anything')).wont_be_empty
          _(SolutionLoader.load('anything')).wont_be_empty
          _(StudentFileLoader.load('anything')).wont_be_empty
          _(TutorPersonaLoader.load('anything')).wont_be_empty
        end
      end
    end
  end
end
