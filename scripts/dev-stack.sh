#!/usr/bin/env bash
# Starts a complete local stack for manual validation: PostgreSQL (podman, unless DATABASE_URL is given), migrations,
# sample plan/stage data, the REST API (uvicorn) and the job workers (same queue split as the systemd units), plus a
# watch-dog loop. Ctrl-C stops everything. GitHub, Bamboo and Slack are NOT contacted unless you configure them.
#
#   scripts/dev-stack.sh                 # PORT=9292, PYTHON=.venv/bin/python (or python3.15)
#   PORT=8080 PYTHON=python3.15 scripts/dev-stack.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=${PORT:-9292}
PYTHON=${PYTHON:-$([ -x .venv/bin/python ] && echo .venv/bin/python || echo python3.15)}
RUN_DIR=${RUN_DIR:-.dev-stack}
PG_NAME=netdef-dev-pg
PG_PORT=${PG_PORT:-55433}
WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL:-60}
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/prometheus"

export PYTHONPATH=src PYTHONDONTWRITEBYTECODE=1
export NETDEF_ENV=development DEBUG=true
export WEBHOOK_SECRET=${WEBHOOK_SECRET:-dev-webhook-secret-change-me}
export METRICS_USERNAME=${METRICS_USERNAME:-prometheus} METRICS_PASSWORD=${METRICS_PASSWORD:-prometheus}
export PROMETHEUS_MULTIPROC_DIR="$PWD/$RUN_DIR/prometheus"
export LOG_DIR="$PWD/$RUN_DIR/logs"
export STATUS_DEBOUNCE_SECONDS=${STATUS_DEBOUNCE_SECONDS:-5} CREATE_EXECUTION_DELAY_SECONDS=${CREATE_EXECUTION_DELAY_SECONDS:-1}
export WEB_WORKERS=2
export JOB_SLEEP_DELAY_SECONDS=${JOB_SLEEP_DELAY_SECONDS:-1}

pids=()
cleanup() {
  echo; echo "Stopping..."
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [ -n "${STARTED_PG:-}" ] && podman rm -f "$PG_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [ -z "${DATABASE_URL:-}" ]; then
  command -v podman >/dev/null || { echo "Set DATABASE_URL or install podman"; exit 1; }
  podman rm -f "$PG_NAME" >/dev/null 2>&1 || true
  podman run -d --name "$PG_NAME" -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=netdef_dev \
    -p "$PG_PORT":5432 docker.io/library/postgres:17 >/dev/null
  STARTED_PG=1
  until podman exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
  export DATABASE_URL="postgresql+psycopg://postgres:postgres@localhost:$PG_PORT/netdef_dev"
fi

echo ">> migrations"; "$PYTHON" -m netdef_ci migrate

echo ">> sample data (plan + stages for example-org/example-repo)"
"$PYTHON" - <<'PY'
from sqlalchemy import select
from netdef_ci.db import init_engine, session_scope
from netdef_ci.models import Plan, StageConfiguration
init_engine()
with session_scope() as s:
    if not s.scalars(select(Plan)).first():
        s.add(Plan(bamboo_ci_plan_name="PROJ-PLAN", github_repo_name="example-org/example-repo", name="plan-a"))
        s.add_all([
            StageConfiguration(bamboo_stage_name="Build", github_check_run_name="Build", position=1, mandatory=True, can_retry=True),
            StageConfiguration(bamboo_stage_name="Tests", github_check_run_name="Tests", position=2, mandatory=True, can_retry=True),
        ])
        s.commit()
PY

start() { name=$1; shift; "$@" >"$RUN_DIR/logs/$name.out" 2>&1 & pids+=($!); echo "   started $name (pid $!)"; }
echo ">> processes (output in $RUN_DIR/logs/*.out)"
start web "$PYTHON" -m uvicorn --factory netdef_ci.web.app:app_factory --host 127.0.0.1 --port "$PORT" --workers 2
start worker-q0-3 "$PYTHON" -m netdef_ci worker --queues 0,1,2,3
start worker-q4-6 "$PYTHON" -m netdef_ci worker --queues 4,5,6
start worker-q7-9 "$PYTHON" -m netdef_ci worker --queues 7,8,9
start worker-create-by-plan "$PYTHON" -m netdef_ci worker --queues create_execution_by_plan
start worker-create-by-comment "$PYTHON" -m netdef_ci worker --queues create_execution_by_comment
start worker-create-by-command "$PYTHON" -m netdef_ci worker --queues create_execution_by_command
start worker-timeout "$PYTHON" -m netdef_ci worker --queues timeout_execution
start worker-topotest "$PYTHON" -m netdef_ci worker --queues fetch_topotest_failures
( while sleep "$WATCHDOG_INTERVAL"; do "$PYTHON" -m netdef_ci watch-dog >>"$RUN_DIR/logs/watch-dog.out" 2>&1 || true; done ) &
pids+=($!); echo "   started watch-dog loop every ${WATCHDOG_INTERVAL}s (pid $!)"

for _ in $(seq 60); do curl -fs "http://127.0.0.1:$PORT/readyz" >/dev/null 2>&1 && break; sleep 0.5; done
echo ">> readiness: $(curl -s http://127.0.0.1:$PORT/readyz)"
BODY='{}'; SIG="sha256=$(printf %s "$BODY" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | sed 's/^.* //')"
echo ">> signed ping: $(curl -s -X POST "http://127.0.0.1:$PORT/" -H 'X-GitHub-Event: ping' -H "X-Hub-Signature-256: $SIG" -d "$BODY")"

cat <<INFO

Stack is up. Try:
  curl http://127.0.0.1:$PORT/ping
  curl -u $METRICS_USERNAME:$METRICS_PASSWORD http://127.0.0.1:$PORT/metrics | grep -E 'delayed_jobs|http_requests'
  BODY='{}'; SIG="sha256=\$(printf %s "\$BODY" | openssl dgst -sha256 -hmac '$WEBHOOK_SECRET' | sed 's/^.* //')"
  curl -X POST http://127.0.0.1:$PORT/ -H 'X-GitHub-Event: ping' -H "X-Hub-Signature-256: \$SIG" -d "\$BODY"
  tail -f $RUN_DIR/logs/*.out        # logs per process ($RUN_DIR/logs/pr<N>.log per pull request)
Press Ctrl-C to stop.
INFO
wait
