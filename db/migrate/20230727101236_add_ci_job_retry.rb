#  SPDX-License-Identifier: BSD-2-Clause
#
#  20230727101236_add_ci_job_retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddCiJobRetry < ActiveRecord::Migration[6.0]
  def change
    add_column :ci_jobs, :retry, :integer, default: 0
  end
end
