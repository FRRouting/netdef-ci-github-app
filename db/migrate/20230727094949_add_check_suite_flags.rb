# frozen_string_literal: true

class AddCheckSuiteFlags < ActiveRecord::Migration[6.0]
  def change
    add_column :check_suites, :re_run, :boolean, default: false
    add_column :check_suites, :retry, :integer, default: 0
  end
end
