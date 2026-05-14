# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:prompt_logs) do
      primary_key :id

      String   :course_id,   null: false
      String   :project_id,  null: false
      String   :student_id,  null: false
      Text     :prompt,      null: false
      Float    :attack_prob             # probability.attack
      Float    :benign_prob             # probability.benign
      Text     :reason                  # model's explanation
      TrueClass :allowed,   null: false, default: true

      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
