#   SPDX-License-Identifier: BSD-2-Clause
#
#   20261121120000_add_webhook_to_ci_jobs.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2026 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

# A job whose Bamboo task list lacks the GitHub Check tasks never calls /update/status: its status is polled
# from Bamboo instead (see Github::Build::JobsWithoutWebhook). Existing jobs keep the old behaviour.
class AddWebhookToCiJobs < ActiveRecord::Migration[6.0]
  def change
    add_column :ci_jobs, :webhook, :boolean, default: true, null: false
  end
end
