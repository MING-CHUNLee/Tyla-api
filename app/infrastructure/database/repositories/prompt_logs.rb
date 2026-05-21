# frozen_string_literal: true

module Tyla
  module Repository
    class PromptLogs
      class << self
        def create(entity)
          db_resource = Database::PromptLogOrm.create(entity.to_attr_hash)
          rebuild_entity(db_resource)
        end

        def find_all(filters = {})
          dataset = Database::PromptLogOrm.order(Sequel.desc(:created_at))
          dataset = dataset.where(student_id: filters[:student_id]) if filters[:student_id]
          dataset = dataset.where(course_id:  filters[:course_id])  if filters[:course_id]
          dataset = dataset.where(project_id: filters[:project_id]) if filters[:project_id]
          dataset.map { |row| rebuild_entity(row) }
        end

        # Update an existing row by id with the given attributes (partial update).
        # Used by the pending-row workflow in HandleTutorChat: a pending row is
        # created with nil attack_probability / evaluation, then back-filled
        # here once the orchestrator returns.
        def update(id, attrs)
          row = Database::PromptLogOrm[id]
          return nil if row.nil?

          row.update(attrs)
          rebuild_entity(row.refresh)
        end

        def rebuild_entity(db_resource)
          return nil if db_resource.nil?

          Entity::PromptLog.new(
            id:                 db_resource.id,
            course_id:          db_resource.course_id,
            project_id:         db_resource.project_id,
            student_id:         db_resource.student_id,
            prompt:             db_resource.prompt,
            attack_probability: db_resource.attack_probability,
            evaluation:         db_resource.evaluation,
            created_at:         db_resource.created_at
          )
        end
      end
    end
  end
end
