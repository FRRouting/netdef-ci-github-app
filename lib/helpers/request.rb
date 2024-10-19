#  SPDX-License-Identifier: BSD-2-Clause
#
#  request.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'net/http'
require 'net/https'
require 'netrc'
require 'json'
require 'multipart/post'

module GitHubApp
  module Request
    def download(uri, machine: 'ci1.netdef.org')
      user, passwd = fetch_user_pass(machine)
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Get.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      http.request(req).body
    end

    def get_request(uri, machine: 'ci1.netdef.org', json: true)
      user, passwd = fetch_user_pass(machine)
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Get.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      # Add JSON request header
      req.add_field 'Accept', 'application/json'

      json ? JSON.parse(http.request(req).body) : http.request(req).body
    rescue StandardError => e
      logger(Logger::ERROR, "HTTP GET Request failed (#{e.message}) for #{uri.host}")
    end

    def delete_request(uri, machine: 'ci1.netdef.org')
      user, passwd = fetch_user_pass(machine)
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Delete.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      # Fetch Request
      resp = http.request(req)
      logger(Logger::DEBUG, resp)

      resp
    end

    def put_request(uri, machine: 'ci1.netdef.org')
      user, passwd = fetch_user_pass(machine)
      http = create_http(uri)

      # Create Request
      req = Net::HTTP::Put.new(uri)
      # Add authorization headers
      req.basic_auth user, passwd

      req.add_field 'Content-Type', 'application/xml'
      req.add_field 'Accept', 'application/json'

      # Fetch Request
      resp = http.request(req)
      logger(Logger::DEBUG, "#{resp.code} - #{resp.body.inspect}")

      resp
    rescue StandardError => e
      logger(Logger::ERROR, "HTTP POST Request failed (#{e.message}) for #{uri.host}")
    end

    def post_request(uri, body: nil, machine: 'ci1.netdef.org')
      user, passwd = fetch_user_pass(machine)
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
      logger(Logger::DEBUG, resp)

      resp
    rescue StandardError => e
      logger(Logger::ERROR, "HTTP POST Request failed (#{e.message}) for #{uri.host}")
    end

    def create_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      http
    end

    def fetch_user_pass(machine)
      netrc = Netrc.read
      netrc[machine]
    end
  end
end
