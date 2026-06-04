# frozen_string_literal: true

require_relative '../../../spec_helper'
require 'sequel'

# SQLite stores DATETIME as a naïve string. Pin Sequel to UTC so a
# client-supplied `Time.utc(...)` round-trips faithfully instead of being
# read back as if it were local time.
Sequel.default_timezone     = :utc
Sequel.application_timezone = :utc

# ── In-memory test database ──────────────────────────────────────────────────
REPO_DB = Sequel.sqlite

REPO_DB.create_table(:prompt_logs) do
  primary_key :id
  String   :course_id,          null: false
  String   :project_id,         null: false
  String   :student_id,         null: false
  Text     :prompt,             null: false
  Float    :attack_probability
  Text     :evaluation
  DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
end

Sequel::Model.db = REPO_DB

require File.join(ROOT, 'app/infrastructure/database/orm/prompt_log_orm.rb')
require File.join(ROOT, 'app/infrastructure/database/repositories/prompt_logs.rb')

describe Tyla::Repository::PromptLogs do
  def build_entity(**overrides)
    Tyla::Entity::PromptLog.new(
      {
        id:                 nil,
        course_id:          'c1',
        project_id:         'p1',
        student_id:         's1',
        prompt:             'hello',
        attack_probability: 0.1,
        evaluation:         'fine',
        created_at:         nil
      }.merge(overrides)
    )
  end

  before do
    Tyla::Database::PromptLogOrm.dataset = REPO_DB[:prompt_logs]
    REPO_DB[:prompt_logs].delete
  end

  describe '.create' do
    it 'persists the entity and returns one with id + created_at populated' do
      saved = Tyla::Repository::PromptLogs.create(build_entity)

      _(saved).must_be_instance_of Tyla::Entity::PromptLog
      _(saved.id).wont_be_nil
      _(saved.created_at).wont_be_nil
      _(saved.course_id).must_equal 'c1'
    end

    it 'persists a client-supplied created_at instead of the DB default' do
      ts    = Time.utc(2026, 5, 14, 10, 0, 0)
      saved = Tyla::Repository::PromptLogs.create(build_entity(created_at: ts))
      _(saved.created_at.to_i).must_equal ts.to_i
    end
  end

  describe '.find_all' do
    before do
      Tyla::Repository::PromptLogs.create(build_entity(student_id: 's1', course_id: 'c1'))
      Tyla::Repository::PromptLogs.create(build_entity(student_id: 's2', course_id: 'c1'))
      Tyla::Repository::PromptLogs.create(build_entity(student_id: 's1', course_id: 'c2'))
    end

    it 'returns all entries when no filter given' do
      results = Tyla::Repository::PromptLogs.find_all
      _(results.size).must_equal 3
      _(results.first).must_be_instance_of Tyla::Entity::PromptLog
    end

    it 'filters by student_id' do
      results = Tyla::Repository::PromptLogs.find_all(student_id: 's1')
      _(results.size).must_equal 2
      results.each { |r| _(r.student_id).must_equal 's1' }
    end

    it 'filters by multiple criteria simultaneously' do
      results = Tyla::Repository::PromptLogs.find_all(student_id: 's1', course_id: 'c1')
      _(results.size).must_equal 1
      _(results.first.student_id).must_equal 's1'
      _(results.first.course_id).must_equal 'c1'
    end

    it 'returns an empty array when no rows match' do
      _(Tyla::Repository::PromptLogs.find_all(student_id: 'nobody')).must_equal []
    end
  end

  describe '.find' do
    it 'returns the entity for an existing id' do
      saved = Tyla::Repository::PromptLogs.create(build_entity(prompt: 'lookup me'))
      found = Tyla::Repository::PromptLogs.find(saved.id)

      _(found).must_be_instance_of Tyla::Entity::PromptLog
      _(found.id).must_equal saved.id
      _(found.prompt).must_equal 'lookup me'
    end

    it 'returns nil when the id is not found' do
      _(Tyla::Repository::PromptLogs.find(-1)).must_be_nil
    end
  end

  describe '.update' do
    it 'back-fills pending fields and returns the refreshed entity' do
      pending = Tyla::Repository::PromptLogs.create(
        build_entity(attack_probability: nil, evaluation: nil)
      )

      updated = Tyla::Repository::PromptLogs.update(
        pending.id,
        attack_probability: 0.2,
        evaluation:         'cleared'
      )

      _(updated.attack_probability).must_equal 0.2
      _(updated.evaluation).must_equal 'cleared'
      _(updated.id).must_equal pending.id
    end

    it 'returns nil when the id is not found' do
      _(Tyla::Repository::PromptLogs.update(-1, evaluation: 'noop')).must_be_nil
    end
  end

  describe '.rebuild_entity' do
    it 'returns nil when given nil' do
      _(Tyla::Repository::PromptLogs.rebuild_entity(nil)).must_be_nil
    end
  end
end
