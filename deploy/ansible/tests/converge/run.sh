#!/usr/bin/env bash
# Local convergence test of the Ansible automation: Debian trixie + systemd in a privileged podman container,
# PostgreSQL in another container, ansible running with a local connection INSIDE the container. No real server is touched.
#   deploy/ansible/tests/converge/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'podman rm -f netdef-ruby-converge >/dev/null 2>&1 || true; podman rm -f netdef-ruby-converge-pg >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

podman build -q -t netdef-ruby-ansible-test -f "$here/Containerfile" "$here" >/dev/null
tar czf "$work/app.tar.gz" -C "$root" --exclude=.git --exclude=.idea --exclude=coverage --exclude=logs --exclude=tmp \
  --exclude=vendor --exclude=.bundle --exclude=config.yml --exclude=config/database.yml --exclude='*.pem' --exclude=deploy .
cp "$here"/inventory.yml "$here"/vault.yml "$here"/converge.sh "$work"/

podman rm -f netdef-ruby-converge-pg >/dev/null 2>&1 || true
podman run -d --name netdef-ruby-converge-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=converge -p 55432:5432 docker.io/library/postgres:17 >/dev/null
until podman exec netdef-ruby-converge-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

podman run -d --name netdef-ruby-converge --privileged --systemd=always --network host \
  -v "$root/deploy/ansible:/ansible:ro,Z" -v "$work:/test:ro,Z" netdef-ruby-ansible-test >/dev/null
sleep 5
c() { podman exec netdef-ruby-converge sh -c "$1"; }
recap() { c "grep -A1 'PLAY RECAP' $1 | tail -1"; }
pb() { c "$1 > /tmp/$2.log 2>&1" || { c "tail -60 /tmp/$2.log"; exit 1; }; recap "/tmp/$2.log"; }
signed_ping() {
  c 'body="{\"zen\":\"converge\"}"; sig=$(printf %s "$body" | openssl dgst -sha256 -hmac converge-webhook-secret | sed "s/^.* //");
     curl -fsS -X POST -H "X-GitHub-Event: ping" -H "X-Hub-Signature-256: sha256=$sig" -d "$body" http://127.0.0.1:9292/; echo'
}

echo "== 1) first deploy (builds Ruby: several minutes)"
pb /test/converge.sh run1
echo "== 2) same release again: must report changed=0"
pb /test/converge.sh run2
echo "== 3) new release, then again (changed=0)"
pb 'RELEASE=second /test/converge.sh' run3
pb 'RELEASE=second /test/converge.sh' run4
echo "== 4) signed GitHub ping, metrics, watch-dog run"
signed_ping
c 'curl -sS -o /dev/null -w "metrics: %{http_code}\n" -u prometheus:converge-metrics http://127.0.0.1:9292/metrics'
c 'systemctl start netdef-ci-ruby-watchdog.service && systemctl show -p Result --value netdef-ci-ruby-watchdog.service'
echo "== 5) rollback"
pb '/test/converge.sh rollback' run5
c 'readlink /opt/netdef-ci-ruby/current; systemctl is-active netdef-ci-ruby-web netdef-ci-ruby-worker-q0-1'
echo "== 6) stop: every unit inactive and disabled; again with changed=0"
pb '/test/converge.sh stop' run6
pb '/test/converge.sh stop' run7
c 'systemctl is-active netdef-ci-ruby-web netdef-ci-ruby-worker-q0-1 netdef-ci-ruby-watchdog.timer; systemctl is-enabled netdef-ci-ruby.target netdef-ci-ruby-web netdef-ci-ruby-watchdog.timer' || true
echo "== 7) start: services back and health check passes"
pb '/test/converge.sh start' run8
signed_ping
c 'systemctl is-active netdef-ci-ruby-web netdef-ci-ruby-worker-q0-1 netdef-ci-ruby-watchdog.timer'
