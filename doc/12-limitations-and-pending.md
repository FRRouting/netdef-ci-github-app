# 12 — Limitations, pending items and required information

## Not validated (and why)

| Item                                                                                           | Reason                                                                                                                         |
|------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| Real integration with GitHub (App authentication, Checks API, reactions), Bamboo and Slack bot | No test credentials/servers and a ban on changing real resources; clients validated with `respx` (HTTP mocks) and test doubles |
| Deploy to dev/production servers                                                               | No addresses/credentials; not authorized. Validated in a local systemd container (see `10`)                                    |
| Byte-for-byte parity of summary/markdown texts with Ruby in real runs                          | Reproduced from the code; no real captures to compare against                                                                  |
| Ruby RSpec suite                                                                               | Not run, to avoid generating artifacts in the Ruby project (which must not be changed)                                         |
| Verification of the Python tarball's sigstore signature                                        | Only size (python.org API) and locally computed SHA-256                                                                        |
| Load/performance                                                                               | No load test                                                                                                                   |
| SELinux/RedHat                                                                                 | Ansible role effectively tested only for Debian/Ubuntu                                                                         |

## Real pending items and limitations

1. **Report scripts** (`reports/*.rb`, `tasks/retrieve_address_sanitizer_error.rb`) were not migrated — they are manual analyses outside the service flow. They can be rewritten on top of the SQLAlchemy models on demand.
2. **`puma_*` and `http_server_*` metrics** do not exist; Grafana panels that depend on them and on the `table` label of `activerecord_*` need adjusting (see `07`).
3. **Ruby queue (`delayed_jobs`)**: pending Ruby jobs are not migrated — they must be drained before the cutover (see `06`).
4. **Registration of `plans`/`stage_configurations`** remains manual in the database (as in Ruby); there is no CLI/UI for it.
5. **Configuration reload**: unlike Ruby (`debug` re-read on every request), any change requires restarting the services.
6. **Timer schedules** (`watch-dog`, `pr-bamboo-sync`) could not be read from the real crontab; the defaults (15 min / 1 h) must be double-checked.
7. **Preserved quirks** (see `07`, section 2), for example the single Plan→PR link, deserve a future modeling review (join table).
8. **Installing Python by compilation** requires development packages and ~5–10 min on the first run; future alternative: internal image/package.
9. **Bamboo TLS**: inherited default `BAMBOO_VERIFY_TLS=false` (access via `127.0.0.1`); enabling it is recommended once a valid certificate exists.
10. **Key/secret rotation** is manual (procedure in `04`).

## Infrastructure information still missing

- SSH addresses/users of the **dev** and **production** servers and the sudo policy.
- URL of the git repository the server accesses (and deploy key, if private) and the release tag convention.
- Bamboo host for `CI_URL`, confirmation of `BAMBOO_BASE_URL` (`https://127.0.0.1`/tunnel) and of the API user.
- `slack_bot_url` and credentials; whether the Slack bot certificate is self-signed (`SLACK_BOT_VERIFY_TLS=false`).
- PostgreSQL credentials for each environment and the backup policy.
- Current Ruby crontab (to align `netdef_ci_timers`) and the public webhook path (`/githubcheck` on the proxy).
- Current webhook secret (`auth_signature.password`) and `.pem` keys of the GitHub Apps of each environment (they must go straight into the Vault).
