#  SPDX-License-Identifier: BSD-2-Clause
#
#  web/app.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Stable entry point named by the systemd web unit (`uvicorn --factory netdef_ci.web.app:app_factory`).

The application lives in `app/github_app.py`. A rollback only switches the release link and restarts the services
(the units are not rendered again), so the unit must name a path that every release provides, including the ones
from before the code moved to `app/`. Do not add code here."""

from __future__ import annotations

from netdef_ci.app.github_app import app_factory

__all__ = ["app_factory"]
