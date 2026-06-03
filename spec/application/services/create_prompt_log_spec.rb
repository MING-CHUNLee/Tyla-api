# frozen_string_literal: true

require_relative '../../spec_helper'
require 'dry/monads'
require 'sequel'
require 'dry-validation'
require 'time'

# ── In-memory test database ────────────────────────────────────────────────────
CPLS_DB = Sequel.sqlite

CPLS_DB.create_table(:prompt_logs) do
  primary_key :id
  String   :course_id,          null: false
  String   :project_id,         null: false
  String   :student_id,         null: false
  Text     :prompt,             null: false
  Float    :attack_probability
  Text     :evaluation
  DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
end

Sequel::Model.db = CPLS_DB

require File.join(ROOT, 'app/infrastructure/database/orm/prompt_log_orm.rb')
require File.join(ROOT, 'app/infrastructure/database/repositories/prompt_logs.rb')
require File.join(ROOT, 'app/application/requests/create_prompt_log.rb')
require File.join(ROOT, 'app/application/services/prompt_logs/create_prompt_log.rb')

module Tyla
  module Services
    describe CreatePromptLog do
      include Dry::Monads[:result]

      let(:valid_params) do
        {
          'course_id'          => 'CS101',
          'project_id'         => 'proj-1',
          'student_id'         => 'stu-xyz',
          'timestamp'          => '2024-01-15T10:00:00Z',
          'userPrompt'         => 'What is polymorphism?',
          'attack_probability' => 0.05,
          'evaluation'         => 'benign'
        }
      end

      before do
        Tyla::Database::PromptLogOrm.dataset = CPLS_DB[:prompt_logs]
        CPLS_DB[:prompt_logs].delete
      end

      # ── (a) Hyphen normalisation ──────────────────────────────────────────────

      it '(a) accepts attack-probability (hyphen) and treats it as attack_probability' do
        params = valid_params.reject { |k, _| k == 'attack_probability' }
                             .merge('attack-probability' => 0.1)
        outcome = CreatePromptLog.new.call(params)
        _(outcome).must_be :success?
        _(outcome.value!.attack_probability).must_equal 0.1
      end

      # ── (b/c/d) Validation failures ───────────────────────────────────────────

      it '(b) returns Failure[:cannot_process] when a required field is missing' do
        outcome = CreatePromptLog.new.call(valid_params.reject { |k, _| k == 'student_id' })
        _(outcome).must_be :failure?
        _(outcome.failure[0]).must_equal :cannot_process
        _(outcome.failure[1]).must_equal 'validation failed'
        _(outcome.failure[2]).must_be_kind_of Hash
      end

      it '(c) returns Failure[:cannot_process] when timestamp is not ISO8601' do
        outcome = CreatePromptLog.new.call(valid_params.merge('timestamp' => 'not-a-date'))
        _(outcome).must_be :failure?
        _(outcome.failure[0]).must_equal :cannot_process
        _(outcome.failure[2]).wont_be :empty?
      end

      it '(d) errors hash includes the offending field key' do
        outcome = CreatePromptLog.new.call(valid_params.reject { |k, _| k == 'userPrompt' })
        _(outcome).must_be :failure?
        errors = outcome.failure[2]
        _(errors).must_include :userPrompt
      end

      # ── (e) Success path ──────────────────────────────────────────────────────

      it '(e) returns Success with a persisted Entity::PromptLog on valid input' do
        outcome = CreatePromptLog.new.call(valid_params)
        _(outcome).must_be :success?
        entity = outcome.value!
        _(entity).must_be_kind_of Entity::PromptLog
        _(entity.id).wont_be_nil
        _(entity.prompt).must_equal 'What is polymorphism?'
        _(entity.student_id).must_equal 'stu-xyz'
      end

      it '(f) persists the row to the database' do
        CreatePromptLog.new.call(valid_params)
        _(CPLS_DB[:prompt_logs].count).must_equal 1
      end

      # ── (g) Repository error path ─────────────────────────────────────────────

      it '(g) returns Failure[:db_error] when the repository raises Sequel::Error' do
        Repository::PromptLogs.stub(:create, ->(*) { raise Sequel::Error, 'boom' }) do
          outcome = CreatePromptLog.new.call(valid_params)
          _(outcome).must_be :failure?
          _(outcome.failure[0]).must_equal :db_error
        end
      end
    end
  end
end
