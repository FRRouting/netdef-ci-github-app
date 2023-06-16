# frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'
require_relative '../bamboo_ci/retry'
require_relative '../bamboo_ci/stop_plan'

require_relative 'check'

module Github
  class ReRun
    def initialize(payload, logger_level: Logger::INFO)
      @logger = Logger.new($stdout)
      @logger.level = logger_level

      @payload = payload
    end

    def start
      return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?
      return [404, 'Action not found'] unless action?

      fetch_old_check_suite

      @github_check = Github::Check.new(@old_check_suite)

      @logger.info ">>> CheckSuite: #{@old_check_suite.inspect}"

      return comment(@github_check) if @old_check_suite.nil?

      check_suite = create_new_check_suite

      stop_previous_execution
      bamboo_plan = start_new_execution(check_suite)

      ci_jobs(check_suite, bamboo_plan)

      [201, 'Starting re-run']
    end

    private

    def fetch_old_check_suite
      @old_check_suite =
        CheckSuite
        .joins(:pull_request)
        .where('commit_sha_ref LIKE ? AND pull_requests.repository = ?',
               "#{sha256}%", repo).last
    end

    def create_new_check_suite
      CheckSuite.create(
        pull_request: @old_check_suite.pull_request,
        author: @old_check_suite.author,
        commit_sha_ref: @old_check_suite.commit_sha_ref,
        work_branch: @old_check_suite.work_branch,
        base_sha_ref: @old_check_suite.base_sha_ref,
        merge_branch: @old_check_suite.merge_branch
      )
    end

    def comment(github_check)
      github_check.add_comment(pr_id, "SHA256 #{sha256} not found", repo)

      [404, 'Command not found']
    end

    def action
      @payload.dig('comment', 'body')
    end

    def pr_id
      @payload.dig('issue', 'number')
    end

    def repo
      @payload.dig('repository', 'full_name')
    end

    def sha256
      action.split.last
    end

    def action?
      action.match? 'CI:rerun' and @payload['action'] == 'created'
    end

    def start_new_execution(check_suite)
      bamboo_plan_run = BambooCi::PlanRun.new(check_suite, logger_level: @logger.level)
      bamboo_plan_run.ci_variables = ci_vars(check_suite)
      bamboo_plan_run.start_plan
      bamboo_plan_run
    end

    def ci_vars(check_suite)
      ci_vars = []
      ci_vars << { value: check_suite.id, name: 'check_suite_id_secret' }
      ci_vars << { value: @github_check.app_id, name: 'app_id_secret' }
      ci_vars << { value: @github_check.installation_id, name: 'app_installation_id_secret' }
      ci_vars << { value: @github_check.signature, name: 'signature_secret' }

      ci_vars
    end

    def stop_previous_execution
      return if @old_check_suite.nil? or @old_check_suite.finished?

      @logger.info 'Stopping previous execution'
      @logger.info @old_check_suite.inspect

      @old_check_suite.ci_jobs.each do |ci_job|
        BambooCi::StopPlan.stop(ci_job.job_ref)

        @logger.warn("Cancelling Job #{ci_job.inspect}")
        ci_job.cancelled(@github_check)
      end
    end

    def ci_jobs(check_suite, bamboo_plan)
      check_suite.update(bamboo_ci_ref: bamboo_plan.bamboo_reference)

      create_ci_jobs(bamboo_plan, check_suite)

      @github_check.add_comment(pr_id, "OK. Re-running commit #{sha256}", repo)
    end

    def create_ci_jobs(bamboo_plan, check_suite)
      jobs = BambooCi::RunningPlan.fetch(bamboo_plan.bamboo_reference)

      jobs.each do |job|
        ci_job = CiJob.create(
          check_suite: check_suite,
          name: job[:name],
          job_ref: job[:job_ref]
        )

        unless ci_job.persisted?
          @logger.error "CiJob error: #{ci_job.errors.messages.inspect}"

          next
        end

        ci_job.create_check_run(@github_check)
      end
    end
  end
end
