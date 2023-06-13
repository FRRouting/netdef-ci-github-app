# frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'

module Github
  class UpdateStatus
    def initialize(payload)
      @status = payload['status']

      @output =
        if payload.dig('output', 'title').nil? and payload.dig('output', 'summary').nil?
          {}
        else
          { title: payload.dig('output', 'title'), summary: payload.dig('output', 'summary') }
        end

      @job = CiJob.find_by(job_ref: payload['bamboo_ref'])
    end

    def update
      return [404, 'CI JOB not found'] if @job.nil?
      return [304, 'Not Modified'] if @job.queued? and @status != 'in_progress' and @job.name != 'Checkout Code'
      return [304, 'Not Modified'] if @job.in_progress? and !%w[success failure].include? @status

      @github_check = Github::Check.new(@job.check_suite)

      case @status
      when 'in_progress'
        @job.in_progress(@github_check)
      when 'success'
        @job.success(@github_check, @output)
      when 'failure'
        @job.failure(@github_check, @output)
      else
        @logger.error "Invalid status: #{@status}"
      end

      if (@job.name.downcase.match? 'code' or @job.name.downcase.match? 'build') and @status == 'failure'
        @job.check_suite.ci_jobs.where(status: :queued).each do |job|
          job.skipped(@github_check)
        end
      end

      [200, 'Success']
    end
  end
end
