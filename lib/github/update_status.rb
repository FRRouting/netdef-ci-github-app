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
      @failures = payload['failures']
    end

    def update
      return [404, 'CI JOB not found'] if @job.nil?
      return [304, 'Not Modified'] if @job.queued? and @status != 'in_progress' and @job.name != 'Checkout Code'
      return [304, 'Not Modified'] if @job.in_progress? and !%w[success failure].include? @status

      @github_check = Github::Check.new(@job.check_suite)

      update_status

      skipping_jobs

      [200, 'Success']
    end

    private

    def failures_stats
      @failures.each do |failure|
        TopotestFailure.create(ci_job: @job,
                               test_suite: failure['suite'],
                               test_case: failure['case'],
                               message: failure['message'],
                               execution_time: failure['execution_time'])
      end
    end

    def update_status
      case @status
      when 'in_progress'
        @job.in_progress(@github_check, @output)
      when 'success'
        @job.success(@github_check, @output)
      when 'failure'
        @job.failure(@github_check, @output)
        failures_stats if @job.name.downcase.match? 'topotest' and @failures.is_a? Array
      else
        @logger.error "Invalid status: #{@status}"
      end
    end

    def skipping_jobs
      return unless @job.name.downcase.match?(/(code|build)/) and @status == 'failure'

      @job.check_suite.ci_jobs.where(status: :queued).each do |job|
        job.skipped(@github_check)
      end
    end
  end
end
