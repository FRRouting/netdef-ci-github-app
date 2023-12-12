#  SPDX-License-Identifier: BSD-2-Clause
#
#  stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class ParentStage < CiJob
  default_scope { where(stage: true) }

  has_many :jobs, class_name: 'CiJob', foreign_key: :parent_stage_id

  def bamboo_stage
    BambooStageTranslation.find_by(github_check_run_name: name)
  end
end
