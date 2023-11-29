#  SPDX-License-Identifier: BSD-2-Clause
#
#  download.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative 'api'

module BambooCi
  class Download
    extend BambooCi::Api

    def self.build_log(url)
      count = 0
      uri = URI(url)

      begin
        body = download(uri).split("\n").last(10).join("\n")

        raise 'Must try' if body.empty?

        body
      rescue StandardError
        count += 1

        sleep 5
        retry if count <= 3

        ''
      end
    end
  end
end
