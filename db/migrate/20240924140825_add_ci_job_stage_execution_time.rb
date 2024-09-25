# frozen_string_literal: true

#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240924140825_add_ci_job_stage_execution_time.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddCiJobStageExecutionTime < ActiveRecord::Migration[6.0]
  def change
    add_column :ci_jobs, :execution_time, :integer
    add_column :stages, :execution_time, :integer
  end
end
