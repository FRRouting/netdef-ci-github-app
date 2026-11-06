# 13 — Creating, installing and activating the GitHub App

This is the end-to-end procedure that takes a repository from "no CI" to "check runs appear on every Pull Request":
create (or reuse) the GitHub App on GitHub, install it on the repository, deliver its key and webhook secret to the
server with Ansible, and verify the whole path. The reference tables (settings, secrets, rotation) stay in
[04](04-configuration-and-environment.md); the Bamboo side (plans and stages) is in [12](12-adding-a-plan.md).

An existing App can be reused: there is **no need to create a new App** for a new server or a new deploy. Create one
only for a new GitHub account/organization (see [One installation per App](#one-installation-per-app)).

## The whole path at a glance

```mermaid
flowchart TD
    A[1. Generate the webhook secret] --> B[2. Create the GitHub App<br/>webhook URL + secret + permissions + events]
    B --> C[3. Note the App ID and<br/>generate the private key .pem]
    C --> D[4. Install the App on the<br/>organization, selected repositories]
    D --> E[5. Put App ID, repo, .pem and<br/>webhook secret in the Ansible vault]
    E --> F[6. ansible-playbook deploy.yml]
    F --> G[7. check-config on the server]
    G --> H[8. Redeliver the ping<br/>from Recent Deliveries]
    H --> I[9. Register the Bamboo plan<br/>doc/12]
    I --> J[10. Open a test PR:<br/>check runs appear]
```

Where each piece of information ends up:

```mermaid
flowchart LR
    subgraph GitHub["GitHub (App settings)"]
        ID[App ID]
        KEY[Private key .pem]
        SEC[Webhook secret]
        URL[Webhook URL]
    end
    subgraph Vault["Ansible vault.yml"]
        VA["vault_netdef_ci_github_apps<br/>login / repo / private_key"]
        VS[vault_netdef_ci_webhook_secret]
    end
    subgraph Server["Server /etc/netdef-ci"]
        TOML[github_apps.toml]
        PEM["keys/&lt;App ID&gt;.pem"]
        ENV["netdef-ci.env<br/>WEBHOOK_SECRET"]
    end
    ID --> VA
    KEY --> VA
    SEC --> VS
    VA --> TOML
    VA --> PEM
    VS --> ENV
    URL -. reverse proxy .-> WEB[web service<br/>POST /*]
```

## Before you start

- Admin (owner) rights on the GitHub organization that owns the repository, or an organization owner available to
  approve the installation.
- The public URL that reaches the web service. Any path is accepted (`POST /*`); at NetDEF a reverse proxy serves
  `/githubcheck`, e.g. `https://<public-host>/githubcheck`. It must use HTTPS with a valid certificate.
- Access to the Ansible inventory of the target environment (`deploy/ansible/inventories/<env>/`) and its vault
  password ([10](10-ansible-deploy.md)).

## Step 1 — Generate the webhook secret

The same secret signs GitHub webhooks and Bamboo callbacks (`WEBHOOK_SECRET`). The Ansible role refuses values shorter
than 16 characters. Generate a random one:

```bash
openssl rand -hex 32
```

Keep it at hand for steps 2 and 5. When the environment already has a secret in its vault, reuse that value instead:
changing it also requires updating the Bamboo plan (see the rotation table in
[04](04-configuration-and-environment.md#secrets-management-and-rotation)).

## Step 2 — Create the GitHub App

On GitHub, open **Organization → Settings → Developer settings → GitHub Apps → New GitHub App** (the App must be owned
by the organization, not by a personal account). Fill in the form:

| Section                                 | Field                                               | Value                                                                            |
|-----------------------------------------|-----------------------------------------------------|----------------------------------------------------------------------------------|
| Basic information                       | GitHub App name                                     | Name shown on the check runs, e.g. `NetDEF CI`                                   |
| Basic information                       | Homepage URL                                        | Any informative URL (required by GitHub; not used by the service)                |
| Identifying and authorizing users       | Callback URL / *Request user authorization (OAuth)* | Empty / unchecked: the service never acts as a user                              |
| Post installation                       | Setup URL                                           | Empty                                                                            |
| Webhook                                 | Active                                              | Checked                                                                          |
| Webhook                                 | Webhook URL                                         | `https://<public-host>/githubcheck`                                              |
| Webhook                                 | Webhook secret                                      | The value from step 1                                                            |
| Webhook                                 | SSL verification                                    | Enabled                                                                          |
| Permissions → Repository                | Checks                                              | Read and write (create/update check runs)                                        |
| Permissions → Repository                | Pull requests                                       | Read and write (PR info and commits)                                             |
| Permissions → Repository                | Issues                                              | Read and write (comments; `rocket`/`+1`/`-1` reactions on `ci:rerun`/`ci:retry`) |
| Permissions → Repository                | Discussions                                         | Read and write (kept for parity with the current App; not used by the code)      |
| Permissions → Repository                | Metadata                                            | Read-only (mandatory, selected automatically)                                    |
| Subscribe to events                     | Check run, Check suite, Issue comment, Pull request | Checked (required)                                                               |
| Where can this GitHub App be installed? | —                                                   | **Only on this account**                                                         |

The *Subscribe to events* checkboxes only appear after the matching permissions are selected (Checks → Check run and
Check suite; Issues → Issue comment; Pull requests → Pull request). Do not subscribe to other events: they are
answered with `401 Invalid request (4)` and only add noise to *Recent Deliveries*. The `installation` event is always
sent by GitHub and is accepted (`202 Updated`).

Click **Create GitHub App**. GitHub immediately sends a `ping`; it fails if the service is not deployed yet, which is
expected — it is redelivered in step 8.

### Reusing or changing an existing App

To reuse an App, check the same fields on **Settings → Developer settings → GitHub Apps → <App> → Edit**. When you add
a permission to an App that is already installed, GitHub does not apply it immediately: an organization owner must
accept it under **Organization → Settings → GitHub Apps → <App> → Review request**. Until then the service gets `403`
on the calls that need the new permission.

## Step 3 — Note the App ID and generate the private key

On the App's **General** page:

1. Copy the **App ID** (section *About*). It is the `login` of the App in the service configuration.
2. Under **Private keys**, click **Generate a private key**. The browser downloads
   `<app-name>.<date>.private-key.pem`. This is the only copy: GitHub does not keep it.

Treat the `.pem` like a password: do not commit it, do not send it by chat or e-mail, and delete the downloaded file
once it is in the vault (step 5). An App can have several active keys, which is what allows rotation without downtime
([04](04-configuration-and-environment.md#secrets-management-and-rotation)).

## Step 4 — Install the App on the repository

On the App's settings page, open **Install App** (left menu) and click **Install** next to the organization. Choose
**Only select repositories**, select the repository (e.g. `FRRouting/frr`) and confirm with **Install**.

To add a repository later to an App that is already installed: **Organization → Settings → GitHub Apps → <App> →
Configure → Repository access**, add the repository and **Save**. Nothing changes on the server for that, apart from
the `repo` entry of step 5 when the App should be selected for that repository.

### One installation per App

The service authenticates with `GET /app/installations` and uses the **first installation returned**
(`clients/github.py`, `AppAuth.installation_id`). An App must therefore have **exactly one installation** (one
organization). If the same App were installed on two organizations, the service could obtain a token for the wrong one
and every call to the other organization's repositories would fail with `404`/`403`. This is why each environment uses
its own App (`FRRouting/frr` in `prod_frr_public`, `opensourcerouting/private-frr` in `prod_private`). One installation
may cover several repositories of the same organization.

## Step 5 — Put the App in the Ansible vault

Edit the vault of the target environment (`deploy/ansible/inventories/<env>/group_vars/all/vault.yml`; the format is in
`vault.yml.example`):

```bash
cd deploy/ansible
ansible-vault edit inventories/prod_frr_public/group_vars/all/vault.yml
```

```yaml
vault_netdef_ci_webhook_secret: "<value from step 1>"

vault_netdef_ci_github_apps:
  - login: "<App ID from step 3>"
    repo: "FRRouting/frr"            # repository this App serves (selects the App; see below)
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      <contents of the .pem downloaded in step 3>
      -----END RSA PRIVATE KEY-----
```

- Paste the whole `.pem`, including the `BEGIN`/`END` lines, indented under `private_key: |`.
- `repo` is the `<owner>/<repo>` for which this App is chosen. When it is omitted, or no entry matches the PR's
  repository, the service falls back to the first App that authenticates.
- Several Apps are allowed: add one list entry per App.

Ansible renders this into the server (see [10](10-ansible-deploy.md)):

| Vault value                                    | File on the server                                         |
|------------------------------------------------|------------------------------------------------------------|
| `private_key` of each App                      | `/etc/netdef-ci/keys/<App ID>.pem` (`0640 root:netdef-ci`) |
| `login`, `repo` (and the key path) of each App | `/etc/netdef-ci/github_apps.toml` (`GITHUB_APPS_FILE`)     |
| `vault_netdef_ci_webhook_secret`               | `WEBHOOK_SECRET` in `/etc/netdef-ci/netdef-ci.env`         |

For local development without Ansible, copy `github_apps.example.toml` to `github_apps.toml`, set `login`, `cert` (path
of the `.pem`, mode `0600`, outside the repository) and `repo`, and put `WEBHOOK_SECRET` in `.env` (see `README.md`).

## Step 6 — Deploy

```bash
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=<tag>
```

The role validates that `vault_netdef_ci_github_apps` is not empty and that every entry has a `login`, installs the
keys and `github_apps.toml`, and restarts the services when they changed.

## Step 7 — Check the configuration on the server

```bash
sudo -u netdef-ci bash -c 'set -a; . /etc/netdef-ci/netdef-ci.env; set +a; cd /opt/netdef-ci/current && PYTHONPATH=src venv/bin/python -m netdef_ci check-config'
```

It must print `configuration OK`. The
GitHub-related errors it reports are `WEBHOOK_SECRET is empty`, `no GitHub App configured (GITHUB_APPS_FILE)`,
`GITHUB_APPS_FILE unreadable` and `private key of app <App ID> not found: <path>`. `check-config` does not call
GitHub: a wrong key or a missing installation shows up only at the first API call (step 10).

## Step 8 — Redeliver the ping

On the App's settings page open **Advanced → Recent Deliveries**, select the `ping` sent when the App was created and
click **Redeliver**. Expected response: **`200`** with body `PONG!` (or `Duplicate delivery ignored` when that delivery
was already accepted within `WEBHOOK_DEDUPE_TTL_SECONDS`).

| Response                       | Cause                                                         | Fix                                                               |
|--------------------------------|---------------------------------------------------------------|-------------------------------------------------------------------|
| Timeout / connection refused   | Webhook URL wrong, reverse proxy or firewall, service stopped | Check the URL, the proxy and `systemctl status netdef-ci-web`     |
| SSL error                      | Invalid or self-signed certificate on the public host         | Fix the certificate (do not disable SSL verification)             |
| `401 Signatures didn't match!` | Webhook secret on GitHub differs from `WEBHOOK_SECRET`        | Set the same value in the App settings and in the vault, redeploy |
| `404 Signature not found`      | The request reached the service without a signature header    | Make sure the proxy forwards `X-Hub-Signature-256`                |
| `502`/`503` from the proxy     | The web service is down or not listening on the proxied port  | `systemctl status netdef-ci-web`, `GET /readyz`                   |

Also check `GET https://<public-host>/readyz` → `200 {"status":"ready","database":"ok"}`.

## Step 9 — Register the Bamboo plan

Without a plan for the repository, every PR is answered with `422 No Plans associated…`. Follow
[12](12-adding-a-plan.md): plan row, stage configurations and the Bamboo notification script that posts to
`/update/status`.

## Step 10 — Activate: open a test Pull Request

Open (or push to) a Pull Request on the repository and check, in this order:

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant Web as web (POST /*)
    participant W as worker
    participant B as Bamboo
    Dev->>GH: opens / updates the PR
    GH->>Web: pull_request webhook (HMAC)
    Web-->>GH: 200/202 (Recent Deliveries)
    Web->>W: enqueues the plan execution
    W->>GH: JWT → /app/installations → installation token
    W->>B: starts the plan
    W->>GH: creates the check runs (queued)
    B->>Web: POST /update/status (HMAC)
    Web->>GH: updates the check runs
```

1. **Recent Deliveries** shows the `pull_request` delivery answered with `200`/`202`.
2. The PR's **Checks** tab shows the App's check runs (one per stage) in *queued* / *in progress*.
3. The Bamboo plan is running.
4. A `ci:retry` comment on the PR gets a reaction from the App.

When the delivery is accepted but no check run appears, look at the PR log and at
[09 — troubleshooting](09-operations.md): `Github Authentication Failed` / `GitHub App <App ID> could not authenticate` means a wrong App
ID or key, a key that was revoked, or an App not installed on the repository (step 4);
`403 Resource not accessible by integration` means a missing permission or a permission change not yet approved
(step 2).

## Removing an App or a repository

- **Stop serving a repository:** remove it from the installation (**Configure → Repository access**) and remove its
  plan ([12](12-adding-a-plan.md)).
- **Retire an App:** remove its entry from `vault_netdef_ci_github_apps`, redeploy, then uninstall it on GitHub
  (**Organization → Settings → GitHub Apps → <App> → Configure → Uninstall**) and delete its private keys.
