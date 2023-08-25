#!/bin/bash

#
#  SPDX-License-Identifier: BSD-2-Clause
#
#  server.sh
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true
#

echo ">> Running migration"
rake db:migrate

echo ">> Running server"
RAILS_ENV=production RACK_ENV=production rackup -o 0.0.0.0 -p 4667 config.ru
