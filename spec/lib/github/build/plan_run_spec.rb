#   SPDX-License-Identifier: BSD-2-Clause
#
#   plan_run_spec.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true
#

describe Github::Build::PlanRun do
  let(:plan_run) { described_class.new(pull_request, payload) }

  context 'when receives an invalid pull request' do
    let(:pull_request) { create(:pull_request, plans: []) }
    let(:payload) { {} }

    it 'must return 422' do
      expect(plan_run.build).to eq([422, 'No Plans associated with this Pull Request'])
    end
  end
end
