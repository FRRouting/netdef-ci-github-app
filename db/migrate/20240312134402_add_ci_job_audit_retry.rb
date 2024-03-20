#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240312134402_add_ci_job_audit_retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddCiJobAuditRetry < ActiveRecord::Migration[6.0]
  def change
    create_table :audit_retries_ci_jobs, id: false do |t|
      t.belongs_to :ci_job
      t.belongs_to :audit_retry
    end
  end
end
