# frozen_string_literal: true

Sequel.migration do
  up   { alter_table(:prompt_logs) { set_column_allow_null :allowed } }
  down { alter_table(:prompt_logs) { set_column_not_null :allowed, default: true } }
end
