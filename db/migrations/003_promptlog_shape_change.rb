# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:prompt_logs) do
      drop_column :benign_prob
      drop_column :allowed
      rename_column :reason,      :evaluation
      rename_column :attack_prob, :attack_probability
    end
  end

  down do
    alter_table(:prompt_logs) do
      rename_column :attack_probability, :attack_prob
      rename_column :evaluation,         :reason
      add_column :allowed,     TrueClass, default: true
      add_column :benign_prob, Float
    end
  end
end
