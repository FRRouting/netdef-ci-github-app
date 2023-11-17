#
#  SPDX-License-Identifier: BSD-2-Clause
#
#  watch_dog.sh
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true
#
#/bin/bash

# shellcheck disable=SC2164
cd /home/githubchecks/server
RACK_ENV=production ruby workers/watch_dog.rb
