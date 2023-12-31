#  SPDX-License-Identifier: BSD-2-Clause
#
#  stage_configuration.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class StageConfiguration < ActiveRecord::Base
  validates :bamboo_stage_name, presence: true
  validates :github_check_run_name, presence: true
end
