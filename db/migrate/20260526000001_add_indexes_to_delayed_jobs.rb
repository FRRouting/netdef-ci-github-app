#  SPDX-License-Identifier: BSD-2-Clause
#
#  20260526000001_add_indexes_to_delayed_jobs.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddIndexesToDelayedJobs < ActiveRecord::Migration[7.2]
  def change
    # Composite index for the main polling query:
    # SELECT * FROM delayed_jobs WHERE run_at <= NOW() AND locked_at IS NULL AND failed_at IS NULL
    # ORDER BY priority ASC, run_at ASC LIMIT N
    add_index :delayed_jobs, %i[priority run_at],
              where: 'locked_at IS NULL AND failed_at IS NULL',
              name: 'index_delayed_jobs_on_priority_and_run_at'

    # Index for locking queries (worker claims a job):
    # SELECT * FROM delayed_jobs WHERE locked_at IS NOT NULL ...
    add_index :delayed_jobs, :locked_at,
              where: 'locked_at IS NOT NULL',
              name: 'index_delayed_jobs_on_locked_at'

    # Index for failed job queries used by PrometheusMetrics:
    # SELECT * FROM delayed_jobs WHERE failed_at IS NOT NULL ...
    add_index :delayed_jobs, :failed_at,
              where: 'failed_at IS NOT NULL',
              name: 'index_delayed_jobs_on_failed_at'
  end
end
