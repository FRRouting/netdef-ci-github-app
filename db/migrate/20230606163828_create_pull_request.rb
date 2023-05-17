# frozen_string_literal: true

class CreatePullRequest < ActiveRecord::Migration[6.0]
  def change
    create_table :pull_request do |t|
      t.string :author, null: false
      t.string :github_pr_id, null: false
      t.string :branch_name, null: false
      t.string :repository, null: false
      t.string :plan

      t.timestamps
    end
  end
end
