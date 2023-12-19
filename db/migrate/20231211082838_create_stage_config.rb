#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231023090822_create_pull_request_subscribe.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateStageConfig < ActiveRecord::Migration[6.0]
  def change
    create_table :stage_configurations do |t|
      t.string :bamboo_stage_name, null: false
      t.string :github_check_run_name, null: false
      t.boolean :start_in_progress, default: false
      t.boolean :can_retry, default: true
      t.integer :position
      t.boolean :mandatory, default: true

      t.timestamps
    end

    [
      ['Get Sourcecode', 'Verify Source', true, false],
      ['Building Stage', 'Build', false, true],
      ['Basic Tests', 'Tests', false, true]
    ].each_with_index do |info, index|
      StageConfiguration.create(bamboo_stage_name: info[0],
                                    github_check_run_name: info[1],
                                    start_in_progress: info[2],
                                    can_retry: info[3],
                                    position: index)
    end
  end
end
