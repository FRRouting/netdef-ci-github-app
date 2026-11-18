#  SPDX-License-Identifier: BSD-2-Clause
#
#  stop_plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative 'api'
require_relative 'running_plan'

module BambooCi
  class StopPlan
    extend BambooCi::Api

    def self.stop(job_key)
      PrometheusMetrics.track_bamboo('stop_job') { delete_from_queue(job_key) }
    end

    def self.build(bamboo_ci_ref)
      PrometheusMetrics.track_bamboo('stop_plan') do
        next stop_by_rest(bamboo_ci_ref) if BambooCi::ServiceAccount.instance.configured?

        get_request(URI("https://127.0.0.1/build/admin/stopPlan.action?planResultKey=#{bamboo_ci_ref}"))
      end
    end

    # Whether Bamboo stopped the execution, for callers that record a cancellation in GitHub.
    # stopPlan.action (no service account) answers with an HTML page, so its result cannot be told
    # and the execution is taken as stopped, as before.
    def self.stop_execution(bamboo_ci_ref)
      response = build(bamboo_ci_ref)

      return true if bamboo_ci_ref.nil? or !BambooCi::ServiceAccount.instance.configured?

      stop_accepted?(response)
    end

    # A service account token only authenticates REST endpoints, so stopPlan.action is not an option.
    # The queue DELETE of the execution only stops it while it waits in the queue, so it is also sent to each job.
    # Returns the first refused job DELETE (or the execution response when every job was stopped).
    # A 404 on the execution only means it is no longer queued. Without the job list (Bamboo error, refused
    # token) its jobs cannot be stopped either, so the stop is not confirmed and nil is returned, unless
    # Bamboo no longer knows the build at all (expired or deleted result), which leaves nothing to stop.
    def self.stop_by_rest(bamboo_ci_ref)
      return nil if bamboo_ci_ref.nil?

      response = delete_from_queue(bamboo_ci_ref)
      result = fetch_result(bamboo_ci_ref)

      return response if unknown_to_bamboo?(response, result)

      job_refs = job_refs(result)
      return unconfirmed_stop(bamboo_ci_ref) if job_refs.empty? and !response.is_a?(Net::HTTPSuccess)

      stop_jobs(job_refs, response)
    end

    def self.fetch_result(bamboo_ci_ref)
      get_request_with_status(URI("https://127.0.0.1/rest/api/latest/result/#{bamboo_ci_ref}" \
                                  '?expand=stages.stage.results'))
    end

    def self.unknown_to_bamboo?(response, result)
      response&.code.to_i == 404 and result.is_a?(Hash) and result['http-status'] == 404
    end

    def self.job_refs(result)
      return [] unless result.is_a?(Hash) and result.dig('stages', 'stage').is_a?(Array)

      BambooCi::RunningPlan.mount_jobs(result).filter_map { |job| job[:job_ref] }
    end

    # Every job is sent its DELETE. Returns the first refused answer (nil when that request failed),
    # or the execution response when every job was stopped.
    def self.stop_jobs(job_refs, response)
      refused = job_refs.map { |job_ref| delete_from_queue(job_ref) }.reject { |answer| stop_accepted?(answer) }

      refused.empty? ? response : refused.first
    end

    def self.unconfirmed_stop(bamboo_ci_ref)
      logger(Logger::ERROR, "Could not confirm the stop of #{bamboo_ci_ref}: Bamboo did not list its jobs")

      nil
    end

    # 404: the build or job is no longer in the queue (already finished), so there is nothing left to stop.
    # A request that raises (network error) counts as refused: nil is returned and the error logged.
    def self.delete_from_queue(key)
      response = delete_request(URI("https://127.0.0.1/rest/api/latest/queue/#{key}"))
      return response if stop_accepted?(response)

      logger(Logger::ERROR, "Bamboo refused to stop #{key}: HTTP #{response&.code} " \
                            "#{response.nil? ? '' : BambooCi::ServiceAccount.summary(response)}")

      response
    rescue StandardError => e
      logger(Logger::ERROR, "Bamboo stop request for #{key} failed: #{e.class}: #{e.message}\n" \
                            "#{Array(e.backtrace).first(10).join("\n")}")

      nil
    end

    def self.stop_accepted?(response)
      !response.nil? and (response.is_a?(Net::HTTPSuccess) or response.code.to_i == 404)
    end

    def self.logger(severity, message)
      @app_logger ||= GithubLogger.instance.create('github_app.log', Logger::INFO)
      @app_logger.add(severity, message)
    end

    def self.comment(check_suite, new_check_suite)
      new_url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{new_check_suite.bamboo_ci_ref}"
      comment = "This execution was cancelled due to a new commit or `ci:rerun` (#{new_url})"

      add_comment_to_ci(check_suite.bamboo_ci_ref, comment)
    end
  end
end
