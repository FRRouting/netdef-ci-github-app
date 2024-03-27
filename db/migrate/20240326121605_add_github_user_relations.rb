#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240326121605_add_github_user_relations.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddGithubUserRelations < ActiveRecord::Migration[6.0]
  def change
    add_reference :pull_requests, :github_user, foreign_key: true
    add_reference :check_suites, :github_user, foreign_key: true
    add_reference :audit_retries, :github_user, foreign_key: true
  end
end

