#  SPDX-License-Identifier: BSD-2-Clause
#
#  delayed_job_lookup_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe DelayedJobLookup do
  def enqueue(method, arg, queue: 'timeout_execution')
    Delayed::Job.create!(
      queue: queue,
      handler: "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/class 'TimeoutExecution'\n" \
               "method_name: :#{method}\nargs:\n- #{arg}\n"
    )
  end

  describe '.pending' do
    let!(:target) { enqueue(:timeout, 'PLAN-12') }

    before do
      enqueue(:timeout, 'PLAN-123')
      enqueue(:update, 'PLAN-12')
      enqueue(:timeout, 'PLAN-12', queue: 'other')
    end

    it 'matches the method, the exact first argument and the queue' do
      expect(described_class.pending(queue: 'timeout_execution', method: :timeout, first_arg: 'PLAN-12'))
        .to contain_exactly(target)
    end

    it 'looks in every queue when none is given' do
      expect(described_class.pending(method: :timeout, first_arg: 'PLAN-12').count).to eq(2)
    end

    it 'treats LIKE wildcards in the argument literally' do
      expect(described_class.pending(method: :timeout, first_arg: 'PLAN-1_')).to be_empty
    end
  end
end
