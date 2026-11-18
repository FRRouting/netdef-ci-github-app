#  SPDX-License-Identifier: BSD-2-Clause
#
#  delayed_job_lookup.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

# Finds pending Delayed Job calls by method and first argument. Delayed Job stores the call as YAML with one
# argument per line, so the trailing newline stops "PLAN-12" from matching "PLAN-123". Keep this the only
# place that knows the handler layout.
module DelayedJobLookup
  def self.pending(method:, first_arg:, queue: nil)
    arg = ActiveRecord::Base.sanitize_sql_like(first_arg.to_s)
    jobs = Delayed::Job.where('handler LIKE ?', "%method_name: :#{method}\nargs:\n- #{arg}\n%")

    queue.nil? ? jobs : jobs.where(queue: queue)
  end
end
