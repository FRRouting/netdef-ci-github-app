# 12 — Limitations, pending items and required information

## Not validated (and why)

| Item                                                                                           | Reason                                                                                                                         |
|------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| Real integration with GitHub (App authentication, Checks API, reactions), Bamboo and Slack bot | No test credentials/servers and a ban on changing real resources; clients validated with `respx` (HTTP mocks) and test doubles |
| Deploy to dev/production servers                                                               | No addresses/credentials; not authorized. Validated in a local systemd container (see `10`)                                    |
| Byte-for-byte content of summary/markdown texts in real runs                                   | Produced from the code; no real captures to compare against                                                                    |
| Verification of the Python tarball's sigstore signature                                        | Only size (python.org API) and locally computed SHA-256                                                                        |
| Load/performance                                                                               | No load test                                                                                                                   |
| SELinux/RedHat                                                                                 | Ansible role effectively tested only for Debian/Ubuntu                                                                         |

## Real pending items and limitations

1. **Registration of `plans`/`stage_configurations`** remains manual in the database; there is no CLI/UI for it.
2. **Configuration reload**: any change requires restarting the services.
3. **Timer schedules** (`watch-dog`, `pr-bamboo-sync`) could not be read from the real crontab; the defaults (15 min / 1 h) must be double-checked.
4. **Known quirks** (see `07`, section 2), for example the single Plan→PR link, deserve a future modeling review (join table).
5. **Installing Python by compilation** requires development packages and ~5–10 min on the first run; future alternative: internal image/package.
6. **Bamboo TLS**: default `BAMBOO_VERIFY_TLS=false` (access via `127.0.0.1`); enabling it is recommended once a valid certificate exists.
7. **Key/secret rotation** is manual (procedure in `04`).

## Infrastructure information still missing

- SSH addresses/users of the **dev** and **production** servers and the sudo policy.
- URL of the git repository the server accesses (and deploy key, if private) and the release tag convention.
- Bamboo host for `CI_URL`, confirmation of `BAMBOO_BASE_URL` (`https://127.0.0.1`/tunnel) and of the API user.
- `SLACK_BOT_URL` and credentials; whether the Slack bot certificate is self-signed (`SLACK_BOT_VERIFY_TLS=false`).
- PostgreSQL credentials for each environment and the backup policy.
- Current crontab schedule (to align `netdef_ci_timers`) and the public webhook path (`/githubcheck` on the proxy).
- Current webhook secret (`WEBHOOK_SECRET`) and `.pem` keys of the GitHub Apps of each environment (they must go straight into the Vault).
