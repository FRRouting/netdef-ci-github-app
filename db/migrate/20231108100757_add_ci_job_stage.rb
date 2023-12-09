#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231023090822_create_pull_request_subscribe.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddCiJobStage < ActiveRecord::Migration[6.0]
  def change
    add_column :ci_jobs, :stage, :boolean, default: false
  end
end
