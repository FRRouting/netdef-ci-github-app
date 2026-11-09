#  SPDX-License-Identifier: BSD-2-Clause
#
#  __main__.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`python -m netdef_ci <command>`."""

from netdef_ci.cli.main import main

if __name__ == "__main__":
    raise SystemExit(main())
