# frozen_string_literal: true

require 'net/http'
require 'net/https'
require 'netrc'
require 'json'

module BambooCi
  module Api
    def fetch_executions(plan)
      get_request(URI("https://127.0.0.1/rest/api/latest/search/jobs/#{plan}"))
    end

    def get_status(id)
      get_request(URI("https://127.0.0.1/rest/api/latest/result/#{id}?expand=stages.stage.results,artifacts"))
    end

    def submit_pr_to_ci(bamboo_plan, payload, ci_variables)
      url = "https://127.0.0.1/rest/api/latest/queue/#{bamboo_plan}"

      url += "?customRevision=#{payload['base']['ref']}" \
             "&bamboo.variable.github_repo=#{payload.dig('base', 'repo', 'full_name').gsub('/', '%2F')}" \
             "&bamboo.variable.github_pullreq=#{payload.dig('base', 'ref')}" \
             "&bamboo.variable.github_branch=#{payload.dig('base', 'ref')}" \
             "&bamboo.variable.github_merge_sha=#{payload.dig('head', 'sha')}" \
             "&bamboo.variable.github_base_sha=#{payload.dig('base', 'sha')}"

      ci_variables.each do |variable|
        url += "&bamboo.variable.github_#{variable[:name]}=#{variable[:value]}"
      end

      @logger.debug "Submission URL:\n  #{url}"

      # Fetch Request
      post_request(URI(url))
    end

    def add_comment_to_ci(key, comment)
      url = "https://127.0.0.1/rest/api/latest/result/#{key}/comment"

      @logger.debug "Comment Submission URL:\n  #{url}"

      # Fetch Request
      post_request(URI(url), body: "<comment><content>#{comment}</content></comment>")
    end

    def get_request(uri)
      user, passwd = fetch_user_pass
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Get.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      # Add JSON request header
      req.add_field 'Accept', 'application/json'

      JSON.parse(http.request(req).body)
    rescue StandardError => e
      @logger.error "HTTP GET Request failed (#{e.message}) for #{uri.host}"

      nil
    end

    def delete_request(uri)
      user, passwd = fetch_user_pass
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Delete.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      # Fetch Request
      resp = http.request(req)
      @logger.debug(resp)

      resp
    end

    def put_request(uri)
      user, passwd = fetch_user_pass
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Put.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      req.add_field 'Content-Type', 'application/xml'
      req.add_field 'Accept', 'application/json'

      # Fetch Request
      resp = http.request(req)
      @logger.debug("#{resp.code} - #{resp.body.inspect}")

      resp
    rescue StandardError => e
      @logger.error "HTTP POST Request failed (#{e.message}) for #{uri.host}"

      nil
    end

    def post_request(uri, body: nil)
      user, passwd = fetch_user_pass
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Post.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      unless body.nil?
        # Add headers
        req.add_field 'Content-Type', 'application/xml'
        req.body = body
      end

      req.add_field 'Accept', 'application/json'

      # Fetch Request
      resp = http.request(req)
      @logger.debug(resp)

      resp
    rescue StandardError => e
      @logger.error "HTTP POST Request failed (#{e.message}) for #{uri.host}"

      nil
    end

    def create_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      http
    end

    def fetch_user_pass
      netrc = Netrc.read
      netrc['ci1.netdef.org']
    end
  end
end
