#  SPDX-License-Identifier: BSD-2-Clause
#
#  check_suite.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class CheckSuite < ActiveRecord::Base
  validates :author, presence: true
  validates :commit_sha_ref, presence: true

  belongs_to :pull_request
  has_many :ci_jobs, dependent: :delete_all

  def finished?
    ci_jobs.where(status: %i[queued in_progress]).empty?
  end

  def in_progress?
    !finished?
  end

  def execution_started?
    ci_jobs.where(status: :in_progress).size < 2
  end
end
