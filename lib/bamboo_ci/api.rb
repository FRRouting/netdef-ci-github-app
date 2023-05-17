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

    def submit_pr_to_ci(payload, bamboo_plan, ci_variables)
      url = "https://#{server}/rest/api/latest/queue/#{bamboo_plan}"

      # Add Branch
      url += "?customRevision=#{payload['base']['ref']}"
      # Add Github Repo
      # replace / in github names with %2F
      url += "&bamboo.variable.github_repo=#{payload['base']['repo']['full_name'].gsub("/", "%2F")}"
      # Add Github Pull Request Number
      url += "&bamboo.variable.github_pullreq=#{payload['base']['ref']}"
      # Add Github Merge Branch
      url += "&bamboo.variable.github_branch=#{payload['base']['ref']}"
      # Add Github Merge SHA
      url += "&bamboo.variable.github_merge_sha=#{payload['head']['sha']}"
      # Add Github Base SHA
      url += "&bamboo.variable.github_base_sha=#{payload['base']['sha']}"

      ci_variables.each do |variable|
        url += "&bamboo.variable.github_#{variable[:name]}=#{variable[:value]}"
      end

      @logger.debug "Submission URL:\n  #{url}"

      # Fetch Request
      post_request(URI(url))
    end

    def add_comment_to_ci(key, comment)
      url = "https://127.0.0.1/rest/api/latest/resulta/#{key}/comment"

      @logger.debug "Comment Submission URL:\n  #{url}"

      text = "<comment><content>"
      text += comment
      text += "</content></comment>"

      # Fetch Request
      post_request(URI(url), body: text)
    end

    def get_request(uri)
      netrc = Netrc.read
      user, passwd = netrc['ci1.netdef.org']

      # Create client
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      # Create Request
      req =  Net::HTTP::Get.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      # Add JSON request header
      req.add_field "Accept", "application/json"

      JSON.parse(http.request(req).body)
    rescue StandardError => e
      @logger.error "HTTP GET Request failed (#{e.message}) for #{uri.host}"

      nil
    end

    def delete_request(uri)
      netrc = Netrc.read
      user, passwd = netrc['ci1.netdef.org']

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      # Create Request
      req =  Net::HTTP::Delete.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      # Fetch Request
      resp = http.request(req)
      @logger.debug(resp)

      resp
    end

    def post_request(uri, body: nil)
      netrc = Netrc.read
      user, passwd = netrc['ci1.netdef.org']
      server = '127.0.0.1'

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      # Create Request
      req =  Net::HTTP::Post.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      if body.nil?
        # Add JSON request header
        req.add_field "Accept", "application/json"
      else
        # Add headers
        req.add_field "Content-Type", "application/xml"
        # Add JSON request header
        req.add_field "Accept", "application/json"
      end

      # Fetch Request
      resp = http.request(req)
      @logger.debug(resp)

      resp
    rescue StandardError => e
      @logger.error "HTTP POST Request failed (#{e.message}) for #{uri.host}"

      nil
    end
  end
end
