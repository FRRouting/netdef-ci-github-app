#  SPDX-License-Identifier: BSD-2-Clause
#
#  message_formatter.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module Build
    class Summary
      class MessageFormatter
        def summary_basic_output(stage)
          jobs = stage.jobs.reload

          header = queued_message(jobs)
          header += in_progress_message(jobs)
          header += generate_success_failure_info(stage.name, jobs)

          header[0..65_535]
        end

        def generate_message(name, job)
          failures = tests_message(job)
          failures = build_message(job) if name.downcase.match?('build')
          failures = checkout_message(job) if name.downcase.match?('source')

          "- #{job.name} -> https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{job.job_ref}\n#{failures}"
        end

        private

        def generate_success_failure_info(name, jobs)
          header = ''

          [
            {
              title: ':heavy_multiplication_x: Jobs Failure',
              queue: other_message(name, jobs),
              size: jobs.where.not(status: %i[in_progress queued success]).size
            },
            {
              title: ':heavy_check_mark: Jobs Success',
              queue: success_message(jobs),
              size: jobs.where(status: :success).size
            }
          ].each do |info|
            next if info[:queue].nil? or info[:queue].empty?

            header += "\n#{info[:title]}: #{info[:size]}/#{jobs.size}\n\n#{info[:queue]}"
          end

          header
        end

        def in_progress_message(jobs)
          in_progress = jobs.where(status: :in_progress)

          message = "\n\n:arrow_right: Jobs in progress: #{in_progress.size}/#{jobs.size}\n\n"

          message + jobs.where(status: %i[in_progress]).map do |job|
            "- **#{job.name}** -> https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{job.job_ref}\n"
          end.join("\n")
        end

        def queued_message(jobs)
          queued = jobs.where(status: :queued)

          message = ":arrow_right: Jobs queued: #{queued.size}/#{jobs.size}\n\n"
          message +
            queued.map do |job|
              "- **#{job.name}** -> https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{job.job_ref}\n"
            end.join("\n")
        end

        def success_message(jobs)
          jobs.where(status: :success).map do |job|
            "- **#{job.name}** -> https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{job.job_ref}\n"
          end.join("\n")
        end

        def other_message(name, jobs)
          jobs.where.not(status: %i[in_progress queued success]).map do |job|
            generate_message(name, job)
          end.join("\n")
        end

        def tests_message(job)
          failure = job.topotest_failures.first

          return '' if failure.nil?

          "\t :no_entry_sign: #{failure.test_suite} #{failure.test_case}\n ```\n#{failure.message}\n```\n"
        end

        def checkout_message(job)
          failures = job.summary

          return '' if failures.nil?

          "```\n#{failures.gsub('<br>', "\n")}\n```\n"
        end

        def build_message(job)
          output = BambooCi::Result.fetch(job.job_ref, expand: 'testResults.failedTests.testResult.errors,artifacts')
          entry = output.dig('artifacts', 'artifact')&.find { |elem| elem['name'] == 'ErrorLog' }

          return '' if entry.nil? or entry.empty?

          body = BambooCi::Download.build_log(entry.dig('link', 'href'))

          "```\n#{body}\n```\n"
        end
      end
    end
  end
end
