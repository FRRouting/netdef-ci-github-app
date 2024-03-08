#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214093515_create_retry_stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateRetryStage < ActiveRecord::Migration[6.0]
  def change
    create_table :retry_stages do |t|
      t.text :failure_jobs, null: false
      t.timestamps

      t.references :check_suite, index: true, foreign_key: true
      t.references :stage, index: true, foreign_key: true
    end
  end
end
