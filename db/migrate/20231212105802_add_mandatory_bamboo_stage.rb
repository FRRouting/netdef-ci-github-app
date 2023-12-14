#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231212105802_add_mandatory_bamboo_stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddMandatoryBambooStage < ActiveRecord::Migration[6.0]
  def change
    add_column :bamboo_stage_translations, :mandatory, :boolean, default: true
  end
end
