#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240308094702_alter_group_anonymous_to_public.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AlterGroupAnonymousToPublic < ActiveRecord::Migration[6.0]
  def change
    rename_column :groups, :anonymous, :public
  end
end
