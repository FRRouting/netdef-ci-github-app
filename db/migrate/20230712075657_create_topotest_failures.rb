# frozen_string_literal: true

class CreateTopotestFailures < ActiveRecord::Migration[6.0]
  def change
    create_table :topotest_failures do |t|
      t.string :test_suite, null: false
      t.string :test_case, null: false
      t.string :message, null: false
      t.integer :execution_time, null: false
      t.timestamps

      t.references :ci_job, index: true, foreign_key: true
    end
  end
end
