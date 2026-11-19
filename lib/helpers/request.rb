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
      req = Net::HTTP::Get.new(uri)

      send_request(uri, req, machine).body
    end

    def get_request(uri, machine: 'ci1.netdef.org', json: true)
      req = Net::HTTP::Get.new(uri)
      req.add_field 'Accept', 'application/json'

      body = send_request(uri, req, machine).body

      json ? JSON.parse(body) : body
    rescue StandardError => e
      logger(Logger::ERROR, "HTTP GET Request failed (#{e.message}) for #{uri.host}")

      nil
    end

    # Like get_request, but a JSON object answer also carries the HTTP status as 'http-status': Bamboo's error
    # bodies do not always include their own 'status-code', and a 401/403 must not be read as a missing resource.
    def get_request_with_status(uri, machine: 'ci1.netdef.org')
      req = Net::HTTP::Get.new(uri)
      req.add_field 'Accept', 'application/json'

      resp = send_request(uri, req, machine)
      body = JSON.parse(resp.body)

      body.is_a?(Hash) ? body.merge('http-status' => resp.code.to_i) : body
    rescue StandardError => e
      logger(Logger::ERROR, "HTTP GET Request failed (#{e.message}) for #{uri.host}")

      nil
    end

    def delete_request(uri, machine: 'ci1.netdef.org')
      resp = send_request(uri, Net::HTTP::Delete.new(uri), machine)
      logger(Logger::INFO, resp)

      resp
    end

    def put_request(uri, machine: 'ci1.netdef.org')
      req = Net::HTTP::Put.new(uri)
      req.add_field 'Content-Type', 'application/xml'
      req.add_field 'Accept', 'application/json'

      resp = send_request(uri, req, machine)
      logger(Logger::DEBUG, "#{resp.code} - #{resp.body.inspect}")

      resp
    rescue StandardError => e
      logger(Logger::ERROR, "HTTP PUT Request failed (#{e.message}) for #{uri.host}")

      nil
    end

    def post_request(uri, body: nil, machine: 'ci1.netdef.org')
      req = Net::HTTP::Post.new(uri)

      unless body.nil?
        req.add_field 'Content-Type', 'application/xml'
        req.body = body
      end

      req.add_field 'Accept', 'application/json'

      resp = send_request(uri, req, machine)
      logger(Logger::DEBUG, resp)

      resp
    rescue StandardError => e
      logger(Logger::ERROR, "HTTP POST Request failed (#{e.message}) for #{uri.host}")

      nil
    end

    # Single place where a request is authenticated and sent; BambooCi::Api overrides it for the service account.
    def send_request(uri, req, machine)
      netrc_request(uri, req, machine)
    end

    def netrc_request(uri, req, machine)
      user, passwd = fetch_user_pass(machine)
      req.basic_auth user, passwd

      create_http(uri).request(req)
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
