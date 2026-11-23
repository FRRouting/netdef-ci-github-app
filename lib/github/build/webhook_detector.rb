#  SPDX-License-Identifier: BSD-2-Clause
#
#  webhook_detector.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../bamboo_ci/plan_specs'
require_relative '../../helpers/github_logger'
require_relative '../../helpers/prometheus_metrics'

module Github
  module Build
    # Tells whether a Bamboo job calls back /update/status: its task list must run both GitHub Check scripts.
    # Checkout Code only needs the complete one (UpdateStatus accepts its result without an in_progress hook).
    class WebhookDetector
      UPDATE_SCRIPT = 'ci/github_checks/in_progress.sh'
      COMPLETE_SCRIPT = 'ci/github_checks/complete.sh'

      def initialize(check_suite)
        @check_suite = check_suite
        @logger = GithubLogger.instance.create('github_build_action.log', Logger::INFO)
      end

      # A job the specs do not describe (specs unavailable, job added later) keeps the webhook behaviour.
      def webhook?(job)
        definition = find(job)
        return true if definition.nil?

        missing = required_scripts(job[:name]).reject { |script| runs?(definition, script) }
        return true if missing.empty?

        without_webhook(job, missing)
      end

      private

      def without_webhook(job, missing)
        @logger.warn("Job #{job[:job_ref]} (#{job[:name]}) has no webhook: missing #{missing.join(', ')}")
        PrometheusMetrics::CI_JOBS_WITHOUT_WEBHOOK.increment(labels: { plan: plan_key })

        false
      end

      def required_scripts(name)
        name.to_s.match?(/checkout/i) ? [COMPLETE_SCRIPT] : [UPDATE_SCRIPT, COMPLETE_SCRIPT]
      end

      def runs?(definition, script)
        definition[:commands].any? { |command| command.include?(script) }
      end

      # CiJob#job_ref is the job result key (PROJECT-PLAN-JOB-<build number>).
      def find(job)
        return if specs.nil?

        specs[job[:job_ref].to_s.sub(/-\d+\z/, '')] || specs.values.find { |entry| entry[:name] == job[:name] }
      end

      def specs
        return @specs if defined?(@specs)

        @specs = plan_key.nil? ? nil : BambooCi::PlanSpecs.jobs(plan_key)
        @logger.warn("No Bamboo Specs for #{plan_key}: every job keeps the webhook behaviour") if @specs.nil?

        @specs
      end

      def plan_key
        @check_suite.bamboo_ci_ref&.sub(/-\d+\z/, '')
      end
    end
  end
end
