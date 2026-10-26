#!/usr/bin/env bash
# Runs the full quality gate (ruff, mypy, pytest + coverage) against PostgreSQL with Python 3.15.2, using podman.
#   scripts/test-with-podman.sh            # build image + venv (cached under .venv-podman) + run everything
# Requires: podman and network access (python.org, PyPI, docker.io).
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${IMAGE:-netdef-py315}
PG_NAME=netdef-test-pg
PG_PORT=${PG_PORT:-55432}

podman image exists "$IMAGE" || podman build -t "$IMAGE" -f scripts/Containerfile.dev scripts
mkdir -p .venv-podman
podman rm -f "$PG_NAME" >/dev/null 2>&1 || true
podman run -d --name "$PG_NAME" -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=githubruns-test \
  -p "$PG_PORT":5432 docker.io/library/postgres:17 >/dev/null
trap 'podman rm -f "$PG_NAME" >/dev/null 2>&1 || true' EXIT
until podman exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

run() {
  podman run --rm --network host -e PYTHONDONTWRITEBYTECODE=1 -e PYTHONPATH=/work/src \
    -e TEST_DATABASE_URL="postgresql+psycopg://postgres:postgres@localhost:$PG_PORT/githubruns-test" \
    -v "$PWD/.venv-podman:/venv:Z" -v "$PWD:/work:Z" -w /work "$IMAGE" "$@"
}
[ -x .venv-podman/bin/python ] || run sh -c 'python3.15 -m venv /venv && /venv/bin/pip install -q --only-binary=:all: -r requirements-dev.txt'
run /venv/bin/ruff check src tests migrations
run /venv/bin/ruff format --check src tests migrations
run /venv/bin/mypy src
run /venv/bin/python -m pytest tests --cov --cov-report=term-missing -p no:cacheprovider
