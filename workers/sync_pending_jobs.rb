#  SPDX-License-Identifier: BSD-2-Clause
#
#  sync_pending_jobs.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/setup'

# Reads from Bamboo the result of the jobs an earlier stage left pending (see Summary::PendingJobs),
# outside the webhook that noticed them.
class SyncPendingJobs
  def self.sync(stage_id, agent)
    Github::Build::Summary::PendingJobs.sync_stage(stage_id, agent)
  end
end
