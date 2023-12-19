#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231218084122_change_bamboo_stage_translations_name.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class ChangeBambooStageTranslationsName < ActiveRecord::Migration[6.0]
  def up
    remove_reference :stages, :bamboo_stage_translations, index: true, foreign_key: true
    rename_table :bamboo_stage_translations, :stage_configurations
    add_reference :stages, :stage_configuration, index: true, foreign_key: true
  end

  def down
    remove_reference :stages, :stage_configuration, index: true, foreign_key: true
    rename_table :stage_configurations, :bamboo_stage_translations
    add_reference :stages, :bamboo_stage_translations, index: true, foreign_key: true
  end
end
