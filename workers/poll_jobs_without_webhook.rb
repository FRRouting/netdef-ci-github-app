#  SPDX-License-Identifier: BSD-2-Clause
#
#  poll_jobs_without_webhook.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/setup'

# Reads from Bamboo the status of the jobs that never call /update/status (see Github::Build::JobsWithoutWebhook).
class PollJobsWithoutWebhook
  def self.poll(check_suite_id)
    Github::Build::JobsWithoutWebhook.poll(check_suite_id)
  end
end
