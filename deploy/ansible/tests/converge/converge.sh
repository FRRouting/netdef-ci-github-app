#!/usr/bin/env bash
# Runs a playbook (default: deploy) inside the systemd test container (local connection).
#   converge.sh [playbook] [extra ansible-playbook args]
set -euo pipefail
cd /ansible
export ANSIBLE_CONFIG=/ansible/ansible.cfg ANSIBLE_NOCOLOR=1
playbook="${1:-deploy}"
shift || true
exec ansible-playbook -i /test/inventory.yml "playbooks/${playbook}.yml" -e @/test/vault.yml \
  -e netdef_ci_source_strategy=archive -e netdef_ci_source_archive=/test/app.tar.gz -e "netdef_ci_release_id=${RELEASE:-converge1}" \
  -e netdef_ci_env=development -e netdef_ci_listen_port=9292 -e netdef_ci_web_workers=2 \
  -e netdef_ci_ci_host=ci.example.invalid "$@"
