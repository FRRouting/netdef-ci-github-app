#  SPDX-License-Identifier: BSD-2-Clause
#
#  revert_retry_check.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

# Delayed Job entry point for the GitHub update of a check a failed ci:retry put back to failure.
class RevertRetryCheck
  def self.sync(record_class, record_id, output)
    Github::Build::Retry.sync_reverted_check(record_class, record_id, output)
  end
end
