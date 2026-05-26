#  SPDX-License-Identifier: BSD-2-Clause
#
#  20260526000002_add_indexes_to_ci_jobs_and_stages_status.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddIndexesToCiJobsAndStagesStatus < ActiveRecord::Migration[7.2]
  def change
    # Covers: ci_jobs.where(status: :in_progress)
    #         ci_jobs.where(status: %i[queued in_progress])
    add_index :ci_jobs, :status,
              name: 'index_ci_jobs_on_status'

    # Covers the most common combined filter:
    # ci_jobs.where(check_suite_id: id, status: %i[queued in_progress])
    # check_suite.rb:42 — running_jobs
    # check_suite.rb:50 — execution_started?
    add_index :ci_jobs, %i[check_suite_id status],
              name: 'index_ci_jobs_on_check_suite_id_and_status'

    # Covers: stages.where(status: %i[queued in_progress]).any?
    # check_suite.rb:38 — running?
    add_index :stages, :status,
              name: 'index_stages_on_status'

    # Covers the most common combined filter:
    # stages.where(check_suite_id: id, status: %i[queued in_progress])
    # check_suite.rb:38 — running?
    # stage.rb:42       — running?
    add_index :stages, %i[check_suite_id status],
              name: 'index_stages_on_check_suite_id_and_status'
  end
end
