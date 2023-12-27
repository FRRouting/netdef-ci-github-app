#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214094534_remove_ci_jobs_is_stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class RemoveCiJobsIsStage < ActiveRecord::Migration[6.0]
  def change
    remove_column :ci_jobs, :stage, if_exists: true
    remove_column :ci_jobs, :is_stage, if_exists: true
  end
end
