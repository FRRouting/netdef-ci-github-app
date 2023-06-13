# frozen_string_literal: true

class CreateCheckSuite < ActiveRecord::Migration[6.0]
  def change
    create_table :check_suites do |t|
      t.string :author, null: false
      t.string :commit_sha_ref, null: false
      t.string :base_sha_ref, null: false
      t.string :bamboo_ci_ref
      t.string :merge_branch
      t.string :work_branch
      t.string :details

      t.timestamps

      t.references :pull_request, index: true, foreign_key: true
    end
  end
end
