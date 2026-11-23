#  SPDX-License-Identifier: BSD-2-Clause
#
#  plan_specs.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'json'
require 'logger'
require 'yaml'

require_relative 'api'
require_relative '../helpers/github_logger'
require_relative '../helpers/prometheus_metrics'

module BambooCi
  # Task list of each job of a plan, read from the plan's Bamboo Specs (YAML) export.
  # The export needs the VIEW_CONFIGURATION permission on the plan.
  class PlanSpecs
    extend BambooCi::Api

    # Top-level keys of a YAML spec that are not job definitions.
    PLAN_KEYS = %w[version plan stages variables triggers branches notifications labels other dependencies
                   plan-permissions repositories].freeze

    # Returns { 'PROJECT-PLAN-JOB' => { name:, commands: [...] } } with the text of each enabled task,
    # or nil when Bamboo does not give the specs.
    def self.jobs(plan_key)
      @logger_manager = [GithubLogger.instance.create('github_plan_specs.log', Logger::INFO)]

      document = fetch(plan_key)
      return if document.nil?

      parse(plan_key, document)
    rescue Psych::Exception => e
      logger(Logger::ERROR, "Bamboo Specs of #{plan_key} are not valid YAML: #{e.message}")
      nil
    end

    def self.fetch(plan_key)
      uri = URI(bamboo_url("/rest/api/latest/plan/#{plan_key}/specs?format=YAML"))
      body = PrometheusMetrics.track_bamboo('fetch_plan_specs') { get_request(uri, json: false) }

      code = spec_code(body)
      logger(Logger::WARN, "Bamboo did not export the Specs of #{plan_key}: #{body.to_s[0, 300]}") if code.nil?

      code
    end

    # Bamboo answers JSON ({"spec": {"code": "<yaml>"}}) or the YAML itself; an error is a JSON message.
    def self.spec_code(body)
      return if body.nil? or body.strip.empty?

      json = JSON.parse(body)
      json.is_a?(Hash) ? (json.dig('spec', 'code') || json['code']) : nil
    rescue JSON::ParserError
      body
    end

    def self.parse(plan_key, document)
      documents(document).each_with_object({}) do |spec, jobs|
        next unless spec.is_a?(Hash)

        spec.each do |name, definition|
          next if PLAN_KEYS.include?(name) or !job_definition?(definition)

          jobs["#{plan_key}-#{definition['key']}"] = { name: name, commands: commands(definition) }
        end
      end
    end

    # An export may hold several documents (the plan, then its permissions).
    def self.documents(document)
      document.split(/^---[ \t]*$/).map { |part| YAML.safe_load(part, aliases: true) }
    end

    def self.job_definition?(definition)
      definition.is_a?(Hash) and definition.key?('key') and
        (definition.key?('tasks') or definition.key?('final-tasks'))
    end

    def self.commands(definition)
      tasks = Array(definition['tasks']) + Array(definition['final-tasks'])

      tasks.reject { |task| disabled?(task) }.map { |task| strings(task).join("\n") }
    end

    # A task is a one-key hash ({ 'command' => { ... } }); a disabled one says enabled: false at either level.
    def self.disabled?(task)
      return false unless task.is_a?(Hash)

      task['enabled'] == false or task.values.any? { |value| value.is_a?(Hash) and value['enabled'] == false }
    end

    # A task's description is only a label: naming a script there does not run it.
    def self.strings(value)
      case value
      when Hash then value.except('description').values.flat_map { |item| strings(item) }
      when Array then value.flat_map { |item| strings(item) }
      when String then [value]
      else []
      end
    end
  end
end
