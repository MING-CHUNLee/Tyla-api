# frozen_string_literal: true

require_relative '../../spec_helper'
require 'dry/monads'
require 'sequel'

# ── In-memory test database ────────────────────────────────────────────────────
LPLS_DB = Sequel.sqlite

LPLS_DB.create_table(:prompt_logs) do
  primary_key :id
  String   :course_id,          null: false
  String   :project_id,         null: false
  String   :student_id,         null: false
  Text     :prompt,             null: false
  Float    :attack_probability
  Text     :evaluation
  DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
end

Sequel::Model.db = LPLS_DB

require File.join(ROOT, 'app/infrastructure/database/orm/prompt_log_orm.rb')
require File.join(ROOT, 'app/infrastructure/database/repositories/prompt_logs.rb')
require File.join(ROOT, 'app/application/services/prompt_logs/list_prompt_logs.rb')

module Tyla
  module Services
    describe ListPromptLogs do
      include Dry::Monads[:result]

      let(:valid_params) do
        {
          'student_id' => 'stu-xyz',
          'course_id'  => 'CS101',
          'project_id' => 'proj-1'
        }
      end

      def seed_log(overrides = {})
        attrs = {
          course_id:          'CS101',
          project_id:         'proj-1',
          student_id:         'stu-xyz',
          prompt:             'hello',
          attack_probability: 0.1,
          evaluation:         'benign'
        }.merge(overrides)
        LPLS_DB[:prompt_logs].insert(attrs)
      end

      before do
        Tyla::Database::PromptLogOrm.dataset = LPLS_DB[:prompt_logs]
        LPLS_DB[:prompt_logs].delete
      end

      # ── (a/b/c) Required-filter validation ───────────────────────────────────

      it '(a) returns Failure[:bad_request] when student_id is missing' do
        outcome = ListPromptLogs.new.call(valid_params.except('student_id'))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
        _(outcome.failure.last).must_include 'student_id'
      end

      it '(b) returns Failure[:bad_request] when course_id is missing' do
        outcome = ListPromptLogs.new.call(valid_params.except('course_id'))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
        _(outcome.failure.last).must_include 'course_id'
      end

      it '(c) returns Failure[:bad_request] when project_id is missing' do
        outcome = ListPromptLogs.new.call(valid_params.except('project_id'))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
        _(outcome.failure.last).must_include 'project_id'
      end

      it '(d) treats blank / whitespace-only filters as missing' do
        outcome = ListPromptLogs.new.call(valid_params.merge('student_id' => '   '))
        _(outcome).must_be :failure?
        _(outcome.failure.first).must_equal :bad_request
        _(outcome.failure.last).must_include 'student_id'
      end

      it '(e) lists every missing filter in a single message' do
        outcome = ListPromptLogs.new.call({})
        _(outcome).must_be :failure?
        message = outcome.failure.last
        %w[student_id course_id project_id].each { |k| _(message).must_include k }
      end

      # ── (f/g) Success path ──────────────────────────────────────────────────

      it '(f) returns Success with an empty array when no rows match' do
        outcome = ListPromptLogs.new.call(valid_params)
        _(outcome).must_be :success?
        _(outcome.value!).must_equal []
      end

      it '(g) returns Success with PromptLog entities scoped to the triple' do
        seed_log(student_id: 'stu-xyz', course_id: 'CS101', project_id: 'proj-1', prompt: 'mine')
        seed_log(student_id: 'other', course_id: 'CS101', project_id: 'proj-1', prompt: 'theirs')

        outcome = ListPromptLogs.new.call(valid_params)
        _(outcome).must_be :success?
        entities = outcome.value!
        _(entities.size).must_equal 1
        _(entities.first).must_be_kind_of Entity::PromptLog
        _(entities.first.prompt).must_equal 'mine'
      end

      # ── (h) Repository error path ───────────────────────────────────────────

      it '(h) returns Failure[:db_error] when the repository raises Sequel::Error' do
        Repository::PromptLogs.stub(:find_all, ->(*) { raise Sequel::Error, 'boom' }) do
          outcome = ListPromptLogs.new.call(valid_params)
          _(outcome).must_be :failure?
          _(outcome.failure.first).must_equal :db_error
        end
      end
    end
  end
end
