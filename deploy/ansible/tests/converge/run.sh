#!/usr/bin/env bash
# Local convergence test of the Ansible automation: Debian trixie + systemd in a privileged podman container,
# PostgreSQL in another container, ansible running with a local connection INSIDE the container. No real server is touched.
#   deploy/ansible/tests/converge/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'podman rm -f netdef-converge >/dev/null 2>&1 || true; podman rm -f netdef-converge-pg >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

podman build -q -t netdef-ansible-test -f "$here/Containerfile" "$here" >/dev/null
tar czf "$work/app.tar.gz" -C "$root" --exclude=.git --exclude='.venv*' --exclude=.idea --exclude=__pycache__ --exclude='*.pem' .
cp "$here"/inventory.yml "$here"/vault.yml "$here"/converge.sh "$work"/

podman rm -f netdef-converge-pg >/dev/null 2>&1 || true
podman run -d --name netdef-converge-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=converge -p 55432:5432 docker.io/library/postgres:17 >/dev/null
until podman exec netdef-converge-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

podman run -d --name netdef-converge --privileged --systemd=always --network host \
  -v "$root/deploy/ansible:/ansible:ro,Z" -v "$work:/test:ro,Z" netdef-ansible-test >/dev/null
sleep 5
recap() { podman exec netdef-converge sh -c "grep -A1 'PLAY RECAP' $1 | tail -1"; }

echo "== 1) first deploy (builds Python 3.15.2: several minutes)"
podman exec netdef-converge sh -c '/test/converge.sh > /tmp/run1.log 2>&1' || { podman exec netdef-converge tail -40 /tmp/run1.log; exit 1; }
recap /tmp/run1.log
echo "== 2) same release again: must report changed=0"
podman exec netdef-converge sh -c '/test/converge.sh > /tmp/run2.log 2>&1'; recap /tmp/run2.log
echo "== 3) new release, then again (changed=0)"
podman exec netdef-converge sh -c 'RELEASE=second /test/converge.sh > /tmp/run3.log 2>&1'; recap /tmp/run3.log
podman exec netdef-converge sh -c 'RELEASE=second /test/converge.sh > /tmp/run4.log 2>&1'; recap /tmp/run4.log
echo "== 4) rollback"
podman exec netdef-converge sh -c 'cd /ansible && ANSIBLE_CONFIG=/ansible/ansible.cfg ansible-playbook -i /test/inventory.yml playbooks/rollback.yml -e @/test/vault.yml -e netdef_ci_env=development -e netdef_ci_listen_port=9292 -e netdef_ci_web_workers=2 > /tmp/run5.log 2>&1'; recap /tmp/run5.log
podman exec netdef-converge sh -c 'readlink /opt/netdef-ci/current; curl -fsS http://127.0.0.1:9292/readyz; echo; systemctl is-active netdef-ci-web netdef-ci-worker-q0-1'
