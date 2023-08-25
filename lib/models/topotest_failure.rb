#  SPDX-License-Identifier: BSD-2-Clause
#
#  topotest_failure.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class TopotestFailure < ActiveRecord::Base
  belongs_to :ci_job

  def to_h
    {
      'suite' => test_suite,
      'case' => test_case,
      'message' => message,
      'execution_time' => execution_time
    }
  end
end
