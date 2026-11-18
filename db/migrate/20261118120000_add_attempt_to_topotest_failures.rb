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
# Each partial retry links an audit_retries row to the job, so the attempt of an existing failure is the
# number of those retries made before it was recorded.
class AddAttemptToTopotestFailures < ActiveRecord::Migration[6.0]
  def up
    add_column :topotest_failures, :attempt, :integer, default: 0, null: false
    add_index :topotest_failures, %i[ci_job_id attempt]
    remove_index :topotest_failures, :ci_job_id

    execute <<~SQL.squish
      UPDATE topotest_failures
      SET attempt = (
        SELECT COUNT(*)
        FROM audit_retries_ci_jobs
        JOIN audit_retries ON audit_retries.id = audit_retries_ci_jobs.audit_retry_id
        WHERE audit_retries_ci_jobs.ci_job_id = topotest_failures.ci_job_id
          AND audit_retries.created_at <= topotest_failures.created_at
      )
    SQL
  end

  def down
    add_index :topotest_failures, :ci_job_id
    remove_index :topotest_failures, %i[ci_job_id attempt]
    remove_column :topotest_failures, :attempt
  end
end
