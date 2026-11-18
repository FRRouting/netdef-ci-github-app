#   SPDX-License-Identifier: BSD-2-Clause
#
#   20261118120000_add_attempt_to_topotest_failures.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2026 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

# Partial retries reuse the same CiJob, so each failure records the attempt (ci_jobs.retry) it came from.
class AddAttemptToTopotestFailures < ActiveRecord::Migration[6.0]
  def up
    add_column :topotest_failures, :attempt, :integer, default: 0, null: false
    add_index :topotest_failures, %i[ci_job_id attempt]

    execute <<~SQL.squish
      UPDATE topotest_failures
      SET attempt = ci_jobs.retry
      FROM ci_jobs
      WHERE ci_jobs.id = topotest_failures.ci_job_id AND ci_jobs.retry IS NOT NULL
    SQL
  end

  def down
    remove_index :topotest_failures, %i[ci_job_id attempt]
    remove_column :topotest_failures, :attempt
  end
end
