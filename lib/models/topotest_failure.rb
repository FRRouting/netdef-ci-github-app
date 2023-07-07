# frozen_string_literal: true

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
