#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214085901_change_stage_to_is_stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class ChangeStageToIsStage < ActiveRecord::Migration[6.0]
  def change
    rename_column :ci_jobs, :parent_stage_id, :stage_id
  end
end
