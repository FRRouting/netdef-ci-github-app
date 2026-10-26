#!/usr/bin/env bash
# Re-resolve and pin the runtime dependencies in a throw-away virtualenv (needs the target Python on PATH).
# Usage: PYTHON=python3.15 scripts/freeze_requirements.sh > requirements.txt
set -euo pipefail
PYTHON="${PYTHON:-python3.15}"
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$PYTHON" -m venv "$tmp/venv"
"$tmp/venv/bin/pip" install -q --only-binary=:all: -r "$here/runtime.in"
echo "# Runtime dependencies, pinned (resolved with $("$PYTHON" --version), wheels only)."
echo "# Regenerate with scripts/freeze_requirements.sh; direct dependencies are listed in scripts/runtime.in."
"$tmp/venv/bin/pip" freeze
