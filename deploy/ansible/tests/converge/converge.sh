#!/usr/bin/env bash
# Runs the deploy playbook inside the systemd test container (local connection).
set -euo pipefail
cd /ansible
export ANSIBLE_CONFIG=/ansible/ansible.cfg ANSIBLE_NOCOLOR=1
ansible-playbook --version | head -1
exec ansible-playbook -i /test/inventory.yml playbooks/deploy.yml -e @/test/vault.yml \
  -e netdef_ci_source_strategy=archive -e netdef_ci_source_archive=/test/app.tar.gz -e "netdef_ci_release_id=${RELEASE:-converge1}" \
  -e netdef_ci_env=development -e netdef_ci_listen_port=9292 -e netdef_ci_web_workers=2 \
  -e '{"netdef_ci_settings": {"DEBUG": "true", "CI_URL": "ci.example.invalid"}}' "$@"
