# frozen_string_literal: true

class AddCiJobRetry < ActiveRecord::Migration[6.0]
  def change
    add_column :ci_jobs, :retry, :integer, default: 0
  end
end
