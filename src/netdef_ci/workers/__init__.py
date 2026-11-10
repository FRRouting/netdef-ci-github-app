#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/__init__.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Background jobs, one module per Ruby worker (port of workers/). Each module holds the flow and the
`@job_handler` function that opens a session and delegates to it."""
