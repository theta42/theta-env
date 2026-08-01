# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
correspond to git tags (`vX.Y.Z`). Entries here cover theta-suite's own
orchestration code; see each submodule's own `CHANGELOG.md`
([proxy](https://github.com/theta42/proxy/blob/master/CHANGELOG.md),
[sso-manager-node](https://github.com/theta42/sso-manager-node/blob/master/CHANGELOG.md))
for what changed inside the apps it composes.

## [v1.30.0] - 2026-08-01

The project is renamed **theta-env → theta-suite** — it has grown from a
docker-compose wiring two projects into an integrated suite of four
applications around a shared OpenBao secrets store, and the name should reflect
that. The GitHub repository is renamed `theta42/theta-env` →
`theta42/theta-suite` (old URLs redirect), and the docs site moves to
`https://theta42.github.io/theta-suite/`.

### Changed (theta-suite orchestration)
- **Renamed theta-env → theta-suite** across the superproject: `docs/_config.yml`
  (`title` + `baseurl: /theta-suite` + repo URLs), `README.md`, `setup.sh`
  (incl. the `THETA_SUITE_REEXECED` self-update sentinel), `docker-compose.yml`,
  `bootstrap/bootstrap.js`, `.github/workflows/lint.yml`, `config.example/*`,
  `docs/robots.txt`, all docs pages, and this changelog.
- **Compose project name note:** docker compose derives the project name from
  the clone directory, so named volumes follow it (`<project>_openbao-data`).
  A fresh `git clone` of `theta-suite` uses the `theta-suite` project name; an
  existing deployment that keeps its `theta-env` directory keeps its
  `theta-env_*` volumes — no data migration is required, just don't mix the two.
- **Docs site baseurl** is now `/theta-suite`, matching the renamed repo's
  GitHub Pages URL.

### Docs
- **`architecture.md` rewritten.** Replaced the outdated "The two containers"
  / "The three repos" framing with the actual topology — four always-on
  services (`openbao`, `sso-manager`, `proxy`, `jump-host`) plus the
  `ldap-client` host-enrollment tool — a real diagram, a full **Secrets
  (OpenBao)** section (central store, scoped per-app policies/tokens, the
  `@simpleworkjs/bao-conf` boot overlay, per-user KV, external-app minting),
  and an OpenBao-aware "how config reaches the apps". Removed the
  LDAP-"legacy apps" wording (direct LDAP binds are first-class: Linux hosts
  PAM/SSSD, sudo, SSH keys).
- **`index.md`** — integrated-suite framing; added **Central secrets (OpenBao)**
  and **ldap-client** to "What you get" and "Related projects".
- **`standalone.md` + `README.md`** — standalone is now framed as an advanced
  opt-in; the integrated `./setup.sh` stack is the supported path.

### Submodule bump
- **sso-manager-node → v1.16.1** — fixes the **401 on `/conf` and `/vault`** for
  a logged-in admin. Both view routes 401'd because this app's auth-token is a
  header set by client JS (localStorage), not a cookie, so `req.user` is
  undefined on a browser navigation; the routes now render the shell and gate
  client-side (`app.auth.forceLogin`), with `/api/conf` + `/api/vault` still
  enforcing auth + OpenBao scope server-side. See the
  [sso v1.16.1 release](https://github.com/theta42/sso-manager-node/releases/tag/v1.16.1).

## [v1.29.0] - 2026-08-01

Two fixes for a fresh `./setup.sh` install, plus the SSH jump host promoted
from an opt-in component to a core part of the stack.

### Fixed (theta-suite orchestration)
- **`setup.sh`** — fresh installs aborted silently right after `Minting
  per-app OpenBao tokens`. The `env_get` helper's `grep | cut` pipeline returns
  non-zero under `set -euo pipefail` when `.env` exists (it's created earlier
  by the root-`VAULT_TOKEN` `env_upsert`) but a given app-token key is absent —
  the normal first-run state. The unguarded `existing="$(env_get ...)"` then
  tripped `set -e` and killed the script before any token was minted. `env_get`
  now always returns 0 (`|| true`), so "key absent" resolves to empty and the
  run continues through token minting, the SSO/proxy bring-up, and the jump
  host. Reproduced + verified the fix under the exact fresh-install condition.
- **`setup.sh`** — `JUMP_VAULT_TOKEN` is now always minted (jump host is core;
  the mint was already unconditional, this just documents it).

### Changed (theta-suite orchestration)
- **jump host is no longer optional** — it is built + started on every run,
  with no `CFG_JUMP_HOST_ENABLED` flag.
  - `docker-compose.yml`: removed `profiles: ["jump-host"]` from the
    `jump-host` service so `docker compose up` includes it unconditionally.
    The test-only `ldap-test-host` downstream fixture keeps an opt-in profile,
    renamed `jump-host` → `ldap-test` (`docker compose --profile ldap-test up`).
  - `setup.sh`: `SUBMODULES` always includes `jump-host`; the build/start +
    host-register + summary lines for the jump host are no longer wrapped in a
    `JUMP_ENABLED` guard; the `COMPOSE_PROFILES` export is gone.
  - `bootstrap/bootstrap.js`: jump-host provisioning (mint API token + write
    `jump-secrets.js` + mirror into OpenBao) and its directory service record
    now run unconditionally — no `CFG_JUMP_HOST_ENABLED` gate.
  - `setup.env.example` / `docs/index.md` / `docs/quickstart.md`: dropped the
    "optional / enable with `CFG_JUMP_HOST_ENABLED=true`" wording; the
    `CFG_JUMP_HOST` hostname override + `JUMP_SSH_PORT` remain.

## [v1.28.0] - 2026-08-01

OpenBao becomes the central secrets store for the whole stack. Every app now
loads its secrets from OpenBao at boot via the new
[`@simpleworkjs/bao-conf`](https://simpleworkjs.github.io/bao-conf/) package;
end users get personal per-user secret storage through the SSO UI; external
apps get scoped `secret/apps/<app>/*` access. `setup.sh` mints the policies
and scoped tokens, `bootstrap.js` writes generated creds into OpenBao, and a
new `docs/secrets.md` documents the architecture.

### Changed (theta-suite orchestration)
- **`setup.sh`** — after the KV-v2 enable, a new idempotent block writes four
  OpenBao policies (`sso-broker`, `sso-admin`, `proxy`, `jump-host`) via
  heredocs, a `sso-broker` token role (`allowed_policies_glob` `user-*`/`app-*`,
  24h period), and mints scoped `SSO_VAULT_TOKEN` / `PROXY_VAULT_TOKEN` /
  `JUMP_VAULT_TOKEN` (orphan, renewable, reused from `setup.env` if still
  valid). `seed_app_conf` seeds `secret/{sso-manager,proxy,jump-host}/conf`
  from the operator-edit `/config/*-secrets.js` files on first run. The
  bootstrap exec now passes the root `VAULT_ADDR`/`VAULT_TOKEN` for seeding.
  The root token stays in `setup.env` for maintenance only — it is never passed
  to a service container. `bash -n` + `shellcheck` clean.
- **`docker-compose.yml`** — `sso-manager`/`proxy`/`jump-host` get
  `VAULT_ADDR=http://openbao:8200` and `VAULT_TOKEN=${SSO|PROXY|JUMP}_VAULT_TOKEN:-`;
  `proxy`/`jump-host` gain `depends_on: openbao: service_started`. compose
  config valid.
- **`bootstrap/bootstrap.js`** — `baoPut()` writes the generated OAuth client
  creds to `secret/proxy/conf` and `secret/jump-host/conf` (POST replaces; the
  full file object), so OpenBao — not the on-disk `/config/*-secrets.js` — is
  authoritative after first boot. Fail-soft. `node --check` clean.
- **`docs/secrets.md`** (new) — the full secrets architecture: load path,
  policy/token table, the `sso-broker` role, seeding, end-user personal
  secrets, external-app convention (curl + Node `bao-conf` examples), operator
  rotation, backups. Linked from the README and the docs nav (`_config.yml`).
- **README** — Configuration section rewritten (OpenBao authoritative, link to
  `docs/secrets.md`); Secrets-backup section adds the `openbao-data` volume.

### Submodule bumps
- `sso-manager-node` → **v1.16.0** (was v1.15.2-era).
- `proxy` → **v1.13.1** (was v1.12.1; passes through v1.13.0).
- `jump-host` → **v1.14.1** (was v1.11.0-era; passes through v1.14.0).
- `ldap-client` unchanged (v1.1.1).

#### sso-manager-node — [v1.16.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.16.0)

OpenBao becomes the central secrets store for the theta42 stack, and the SSO
Manager becomes its broker. This is the SSO's half of the move: it loads its
own secrets from OpenBao, mints scoped tokens for users and external apps,
and exposes a fixed, role-scoped personal-secrets UI.

##### Changed
- **Secrets now load from OpenBao at boot** via
  [@simpleworkjs/bao-conf](https://simpleworkjs.github.io/bao-conf/), which
  deep-merges `secret/sso-manager/conf` over the file-loaded config
  (replacing the old `utils/conf_manager.js`, which did a shallow-per-key
  merge). `bin/www` runs `bao-conf.init()` after `models.initORM()` and
  before `listen`. Fail-soft: if OpenBao is unreachable, boot continues from
  `CONF_SECRETS`. The SSO authenticates with a scoped `VAULT_TOKEN` (policy
  `sso-broker`), never the root token. The admin **Configuration** UI
  (`/api/conf`) now writes through `bao-conf.set('sso-manager', …)`.
- **`/api/vault` proxy reworked** — the old endpoint was an ungated
  pass-through that never injected an `X-Vault-Token` (so the UI was both
  ungated *and* broken). It is now `middleware.auth` → `scopeGuard` → a
  token-injecting proxy. `scopeGuard` resolves a per-user (`user-<uid>`) or
  per-admin (`sso-admin`) token via the new `utils/vault_broker.js`
  (Redis-cached, minted through the `sso-broker` token role) and enforces a
  path prefix as a second layer on top of the OpenBao policy. The client
  `auth-token` is stripped; only the server-minted token reaches OpenBao.
- **Vault UI reworked and renamed** (`views/vaultwarden.ejs` →
  `views/vault.ejs`; the `/vault` route is now `middleware.auth`-gated).
  Non-admin users see only their `secret/users/<uid>/` namespace; admins get
  free-form path entry across `secret/` plus an **Apps** tab to mint scoped
  tokens for external apps (`secret/apps/<name>/*`, shown once with copy +
  `curl` convention).
- Bumped package version to track the release tag.

##### Removed
- `nodejs/utils/conf_manager.js` (replaced by `@simpleworkjs/bao-conf`).
- `nodejs/views/vaultwarden.ejs` (renamed `vault.ejs`).

##### Security
- **Committed-secrets remediation.** `config/sso-secrets.js` (LDAP bind
  password, SMTP, `oauth.jwtSecret`) and `nodejs/test_plugins.js` (a
  hardcoded Proxmox root API token and a UniFi password) were tracked on
  master. They are now untracked + gitignored (`config/*-secrets.js`), and
  `test_plugins.js` is deleted; `config/proxy-secrets.js.example` added as a
  placeholder template. **The secrets remain in git history — rotation at
  the providers is the real remediation and is the operator's to perform.**
  OpenBao is now the authoritative store; the local files are seed artifacts
  only.

> Note: sso releases v1.12.0–v1.15.2 were tagged from merge PRs without
> corresponding `CHANGELOG.md` entries or GitHub releases; v1.16.0 resumes
> the changelog.

#### proxy — [v1.13.1](https://github.com/theta42/proxy/releases/tag/v1.13.1) (via [v1.13.0](https://github.com/theta42/proxy/releases/tag/v1.13.0))

##### v1.13.1 — Fixed
- **Bumped `@simpleworkjs/bao-conf` to 1.0.1** so standalone/no-OpenBao boots
  don't crash. bao-conf 1.0.0's `init()` threw when `VAULT_TOKEN` was unset,
  which — combined with `bin/www`'s `.catch(() => process.exit(1))` — made the
  proxy exit at boot in any deployment without an OpenBao sidecar (standalone
  Docker, bare metal). 1.0.1 makes `init()` fail-soft on a missing token (warn
  + continue from `CONF_SECRETS`), matching the documented contract. The
  theta-suite stack is unaffected (it always sets a scoped `VAULT_TOKEN`).

##### v1.13.0 — Changed
- **Secrets now load from OpenBao at boot** via
  [@simpleworkjs/bao-conf](https://simpleworkjs.github.io/bao-conf/), which
  deep-merges `secret/proxy/conf` over the file-loaded config. The proxy
  authenticates to OpenBao with a scoped `VAULT_TOKEN` (policy `proxy` —
  read-only on its own path), never the root token. Because the OIDC
  `clientSecret` is captured at require time inside `createOidcClient` (during
  `require('../models')`, which `require('../app')` triggers transitively),
  `bin/www` now defers `require('../app')` until after `bao-conf.init()`
  resolves. Fail-soft: if OpenBao is unreachable, boot continues from
  `CONF_SECRETS`. The `config/proxy-secrets.js` file is now an operator-edit
  seed artifact (gitignored); OpenBao is authoritative.
- Bumped package version to track the release tag.

#### jump-host — [v1.14.1](https://github.com/theta42/jump-host/releases/tag/v1.14.1) (via [v1.14.0](https://github.com/theta42/jump-host/releases/tag/v1.14.0))

##### v1.14.1 — Fixed
- **Bumped `@simpleworkjs/bao-conf` to 1.0.1** so standalone/no-OpenBao boots
  don't crash. bao-conf 1.0.0's `init()` threw when `VAULT_TOKEN` was unset,
  which — combined with `bin/www`'s `.catch(() => process.exit(1))` — made the
  jump host exit at boot in any deployment without an OpenBao sidecar
  (standalone Docker, bare metal). 1.0.1 makes `init()` fail-soft on a missing
  token (warn + continue from `CONF_SECRETS`), matching the documented
  contract. The theta-suite stack is unaffected (it always sets a scoped
  `VAULT_TOKEN`).

##### v1.14.0 — Changed
- **Secrets now load from OpenBao at boot** via
  [@simpleworkjs/bao-conf](https://simpleworkjs.github.io/bao-conf/), which
  deep-merges `secret/jump-host/conf` over the file-loaded config. The jump
  host authenticates to OpenBao with a scoped `VAULT_TOKEN` (policy
  `jump-host` — read-only on its own path), never the root token. Because the
  OIDC `clientSecret` is captured at require time inside `createOidcClient`
  (during `require('../models')`), `bin/www` now runs `bao-conf.init()`
  **before** `require('../models')`. Fail-soft: if OpenBao is unreachable,
  boot continues from `CONF_SECRETS`. The `config/jump-secrets.js` file is now
  an operator-edit seed artifact (gitignored); OpenBao is authoritative.
- Bumped package version to track the release tag.

## [v1.27.2] - 2026-08-01

- Updated `proxy` to v1.12.1 (Dependabot security/maintenance bumps).

#### proxy — [v1.12.1](https://github.com/theta42/proxy/releases/tag/v1.12.1)

##### Changed
- Bumped `body-parser` 2.2.2 → 2.3.0 (Dependabot #175).
- Bumped `ejs` and `brace-expansion` (Dependabot #179, security maintenance).

## [v1.27.1] - 2026-08-01

- Added automated integration tests for the environment (`test-integration.sh`).
- Updated `sso-manager-node` to v1.15.2 (Directory UI tab styling fixes and Vault documentation).

## [v1.27.0] - 2026-08-01

- Updated `sso-manager-node` to v1.15.0 (UI/UX improvements and structured conf page).

## [v1.26.0] - 2026-08-01

- Made OpenBao production-ready by using a persistent file backend, enabling `IPC_LOCK`, and dynamically generating a robust config file.
- Automated OpenBao initialization, unsealing, and secrets seeding via `setup.sh`.

## [v1.25.0] - 2026-08-01

- Added OpenBao (Vault) container for secrets management and native UI proxying.
- Updated `sso-manager-node` to v1.14.0 (Discovery and Vault integration).
- Updated `proxy` to v1.12.0.

## [Unreleased]

## [1.23.0] - 2026-07-31

### Submodules bumped
- jump-host `v1.12.0` -> [`v1.13.0`](https://github.com/theta42/jump-host/releases/tag/v1.13.0)
- proxy `v1.10.0` -> [`v1.11.0`](https://github.com/theta42/proxy/releases/tag/v1.11.0)
- sso-manager-node `v1.12.0` -> [`v1.13.0`](https://github.com/theta42/sso-manager-node/releases/tag/v1.13.0)

#### jump-host — [v1.13.0](https://github.com/theta42/jump-host/releases/tag/v1.13.0)

##### Changed
- **Title changed to "SSO Manager"** — the jump-host web UI now presents itself as "SSO Manager" in the navbar and page title, matching its role as the unified access portal for both services and hosts.

#### sso-manager-node — [v1.13.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.13.0)

##### Changed
- **Directory page cleaned up** — removed the parent badge and slug display from the directory table; resource names now align with the badges above for a cleaner, more compact layout.
- **Users list SSH key column fixed** — users with multiple SSH keys no longer show multiple checkmarks; the column now shows a single checkmark indicating "has key" regardless of key count.

#### proxy — [v1.11.0](https://github.com/theta42/proxy/releases/tag/v1.11.0)

##### Changed
- **Permissions, Users, and Groups pages converted to table layouts** — card grids replaced with striped tables for better scanability and alignment. Users page adds per-field validation error display alongside the summary message.
- **Groups page auto-refreshes** — adding or removing a group now triggers an explicit reload, ensuring the list stays in sync without manual refresh.

## [1.22.0] - 2026-07-31

### Submodules bumped
- jump-host `v1.11.0` -> [`v1.12.0`](https://github.com/theta42/jump-host/releases/tag/v1.12.0)
- proxy `v1.9.0` -> [`v1.10.0`](https://github.com/theta42/proxy/releases/tag/v1.10.0)
- sso-manager-node `v1.11.0` -> [`v1.12.0`](https://github.com/theta42/sso-manager-node/releases/tag/v1.12.0)

#### jump-host — [v1.12.0](https://github.com/theta42/jump-host/releases/tag/v1.12.0)

##### Added
- **TUI host picker with colors**: ANSI-colored terminal UI with box-drawing header, cyan/magenta/green title treatment, per-row coloring (cyan hostnames, blue IPs), environment badges (red PROD / dim DEV), green inverse selection highlight with "◄ SELECTED ►" indicator, yellow filter text, and a footer separator with quick-select hint.

#### sso-manager-node — [v1.12.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.12.0)

##### Changed
- **Catalog page (`/`) redesigned**: Removed the portal banner; "My Access" section now has tabs separating Services and Hosts; icons support both Font Awesome classes and image URLs (http/https).
- **Profile page redesigned as a single card with tabs**: Password reset is now a modal button; "My groups", "My Services", "Security & Usage Stats", and "Members of X's group" are now tabs on the main profile card instead of separate cards; metrics display fixed to properly load and show service usage data.

#### proxy — [v1.10.0](https://github.com/theta42/proxy/releases/tag/v1.10.0)

##### Changed
- **Permissions page**: Converted from card grid to table/list layout with columns: Subject, Scope, Domain, Role, Actions.
- **Users page**: Converted from card grid to table/list layout; form validation now shows both a summary message AND per-field error messages with visual highlighting.
- **Groups page**: Added automatic refresh after adding/deleting groups to ensure new entries appear immediately.

## [1.21.0] - 2026-07-31

### Submodules bumped
- ldap-client `v1.1.0` -> [`v1.1.1`](https://github.com/theta42/ldap-client/releases/tag/v1.1.1)
- sso-manager-node `v1.10.0` -> [`v1.11.0`](https://github.com/theta42/sso-manager-node/releases/tag/v1.11.0)

> **Operational note — the SSO image now builds slapd from source.** OpenLDAP's
> `nestgroup` overlay (nested groups) exists only on master; no 2.6.x release
> ships it. `Dockerfile.openldap` therefore compiles OpenLDAP from a **pinned**
> commit, which makes the SSO image slower to build and pulls `pw-sha2` from
> contrib. Two consequences worth knowing:
>
> - Master ships **LMDB 1.0.0**, whose on-disk format is mutually unreadable
>   with the 0.9.x in 2.6.x (`MDB_INVALID: File is not an LMDB file`). Moving an
>   existing `/var/lib/ldap` onto this image is a `slapcat` -> `slapadd` reload,
>   not a restart.
> - There is a `TODO` to drop the whole from-source stage once `nestgroup` ships
>   in a release. The entrypoint already probes for `nestgroup.so` and the app
>   keys off `app_ldap__nestedGroupsServerSide`, so that swap needs no other
>   changes.

#### sso-manager-node — [v1.11.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.11.0)

##### Added
- **End-user catalog at `/`** — the first ungated nav item; previously every nav entry was admin-only and a normal user had no signposted destination. Search/filter, per-kind icons, and a *how to reach it* block per card: the URL for a service, the SSH invocation for a host (using the jump-host `uid_-_slug@host` grammar when `directory.jumpHost` is set).
- **Self-service access requests** — `/api/access-requests` (create, list own, list decidable, approve, deny, withdraw) with approve/deny queues on the catalog. Approving performs the LDAP group add, so LDAP stays the access-control truth. Requests target a resource's `_access` group, never `_admin`. Replaces the "coming soon" stub.
- **Admin access visibility** — an Access column on the directory table (member/group counts, flagging links whose LDAP group was deleted) and a "what can this user reach" lookup, the reverse question that previously had no UI at all.
- **Nested LDAP groups.** `groupOfNames.member` already accepts a group DN, so nesting needs no schema — what it needs is resolution, which no released OpenLDAP performs. Server-side via the pinned-master `nestgroup` overlay; client-side the app computes the closure itself (cycle-detected, depth-capped) against any other server. `PUT`/`DELETE /api/group/:group/nested/:child`, `GET /api/group/:group/effective`, and a **Nested** tab on each group card.
- **`app_super_admin` is now seeded** (it never was) and nested into `app_sso_admin` / `app_sso_invite` / `app_sso_oauth_admin`, so the privilege is real LDAP membership visible to SSSD and sudo rather than a special case in app code. Resource creation nests `app_super_admin` -> `<slug>_admin` and `<slug>_admin` -> `<slug>_access`.
- Resource metadata `icon` and `tagline`, collected on the admin form with a live icon preview.

##### Fixed
- **`GET /api/discovery/me` returned only `isPublic` resources for every human caller** — it read `req.user.groups`, which does not exist (`req.user` carries `memberOf`), so the empty list failed open. "My Services" was blank for everyone, and `isDirectoryAdmin()` was false even for real directory admins.
- **The portal's "Discover More Services" was dead for every non-admin** — it called the admin-gated endpoint and swallowed the 403 into an empty array.
- **Services reported no address** — `/me` had reimplemented `getMyAccess` without its parent-walking resolution, so a service reached at its host's IP resolved to nothing.
- `GET /api/user/me` derived `isAdmin` from `memberOf`, which is only transitive with `nestgroup`; against a stock server an admin holding their group via nesting lost the entire admin UI while still passing every server-side check.
- `utils/permission.js`'s `byGroup` saw only direct membership.
- Adding an existing group member, and removing a group's last member, both returned bare 500s; now 409s that explain themselves.
- `DELETE /api/directory-admin/resources/:id` deleted the resource before its edges and group links, orphaning rows on a mid-way failure.
- `/api/directory-admin/audit-logs` shelled out to `tail` via `execSync`; replaced with a bounded async read.
- Broken `api.html` link in the published docs.

##### Changed
- `@simpleworkjs/directory-schema` -> `^1.1.0`, declaring ten metadata keys the admin form always wrote but the schema never listed. Undeclared keys are dropped for non-admin callers — which blanked the portal's `OS:` field, hid every service's port, and left machine tokens unable to read the port mapping the firewall consumer exists to render.

#### ldap-client — [v1.1.1](https://github.com/theta42/ldap-client/releases/tag/v1.1.1)

##### Fixed
- Sets `ldap_group_nesting_level = 5` so SSSD walks nested groups itself when pointed at a server without `nestgroup`. Against the SSO's bundled slapd the existing `memberof=` access filter is already transitive, so SSH login inherits nesting for free. The explicit `app_super_admin` clause is kept, to keep super-admin login working against a directory predating the new nesting.


## [1.20.0] - 2026-07-30

### Added
- **`setup.sh` persists `SSO_GIT_COMMIT`/`PROXY_GIT_COMMIT`/`JUMP_GIT_COMMIT` into `./.env`** (new `env_upsert` helper), which `docker compose` auto-loads on every future invocation in this directory. Previously these were only `export`ed for the current shell, so an ad-hoc `docker compose up --build <service>` run later (outside a full `setup.sh` run) would build with an empty `GIT_COMMIT` arg — and since each submodule's checked-out `.git` is a pointer file, not a real repo, the in-container git fallback can't resolve it either, so the image silently baked "unknown" as its commit hash. `.gitignore`'s `.env` comment updated to describe this (it was previously labeled "legacy, no longer used").

### Submodules bumped
- jump-host `v1.10.2` -> [`v1.11.0`](https://github.com/theta42/jump-host/releases/tag/v1.11.0)
- ldap-client `v1.0.0` -> [`v1.1.0`](https://github.com/theta42/ldap-client/releases/tag/v1.1.0)
- proxy `v1.8.0` -> [`v1.9.0`](https://github.com/theta42/proxy/releases/tag/v1.9.0)
- sso-manager-node `v1.9.0` -> [`v1.10.0`](https://github.com/theta42/sso-manager-node/releases/tag/v1.10.0)

#### sso-manager-node — [v1.10.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.10.0)

##### Added
- `app_super_admin` cross-app group: members are full admins here regardless of `app_sso_admin` membership. The same group is now also recognized by proxy and jump-host, and by `ldap-client`'s SSSD access filter (SSH login on every host).

##### Changed
- Renamed the Executive page to Overview (route, view, `/api/metrics/overview`, nav label, docs). `/executive` kept as a 301 redirect.

#### proxy — [v1.9.0](https://github.com/theta42/proxy/releases/tag/v1.9.0)

##### Added
- `app_super_admin` cross-app group recognized as a global admin (`conf.auth.adminGroups`).

##### Changed
- Users and Permissions pages: the always-visible sidebar "Add" forms are now an "Add User"/"Add Permission" button that opens an `app.modal` dialog, matching the hosts.ejs convention.
- Let's Encrypt ACME account key now defaults to the already-persisted `/data` volume instead of a CWD-relative path (`./le_key.cert` -> `/app/le_key.cert` in the container), which was lost on every image rebuild.

#### jump-host — [v1.11.0](https://github.com/theta42/jump-host/releases/tag/v1.11.0)

##### Added
- `app_super_admin` (cross-app) and `app_jump_admin` groups: super admins are full admins here same as `app_sso_admin`; jump admins get audit page/data access without other admin rights. The Audit page/API is now actually admin-gated server-side (previously the page shell rendered for any logged-in user, only its data was gated).
- Host list adds Last connection/Last failed connection columns and highlights rows green (a session is live right now) or yellow (the most recent attempt failed), backed by new per-host last-success/last-fail timestamps.

##### Changed
- Dashboard's stat boxes and Top hosts/Top users cards moved to the Audit page. "All hosts" renamed to "My hosts".

#### ldap-client — [v1.1.0](https://github.com/theta42/ldap-client/releases/tag/v1.1.0)

##### Added
- `app_super_admin` cross-app group now grants SSH login access to every host (`ldap_access_filter` + `ldap_access_groups`), matching the same group's admin rights in sso-manager-node, proxy, and jump-host. Sudo is not yet extended to super admins (`ldap_sudo_search_filter` remains non-functional on this SSSD version — pre-existing, documented gap).

## [1.19.0] - 2026-07-30

### Added
- **New `ldap-client` submodule + `ldap-test-host` service** (`jump-host` compose profile): a real SSSD + AuthorizedKeysCommand LDAP-joined downstream host for testing jump-host's actual key-injection -> upstream-connect flow end-to-end against this stack's own local LDAP, instead of a container with a manually-dropped public key in `authorized_keys`. Verified live (SSH CLI and WinSCP) through jump-host's `uid_-_target` grammar.

#### ldap-client — [v1.0.0](https://github.com/theta42/ldap-client/releases/tag/v1.0.0) (first tagged release)

##### Added
- Docker test fixture (`Dockerfile` + `entrypoint.sh`): Ubuntu 22.04 + sssd + sshd, no systemd required.

##### Fixed
Building that fixture surfaced three real bugs that would break login on any deployment, not just the test fixture:
- `sssd.conf.mo` used `ldap_bind_dn`/`ldap_bind_pw`, which aren't real SSSD options — corrected to `ldap_default_bind_dn` / `ldap_default_authtok(_type)`.
- `sssd.conf.mo` had no explicit `services =` list, so SSSD started only its backend, never the nss/pam responders — `getent passwd <ldap-user>` silently failed even with the domain reachable.
- `ldap-ssh-key.sh`'s `memberof` filter was missing the `cn=` prefix on the group name, so the AuthorizedKeysCommand script always returned zero keys for a correctly-provisioned user — no error, just silently nothing.

#### sso-manager-node — [v1.9.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.9.0)

##### Added
- Directory modal's Associated LDAP Groups tab now supports full membership management: view, add, and remove members/owners of each associated group directly from the tab.
- `app.util.revealItem()` (shared `app-base.js`): scrolls a just-added/-edited element into view and flashes its background.

##### Changed
- Groups page's search/sort bar is now sticky while scrolling.
- Directory table: Kind/Name/Env/Host merged into a single "Resource" column.

#### proxy — [v1.8.0](https://github.com/theta42/proxy/releases/tag/v1.8.0)

##### Added
- Users backed by SSO/OIDC login are now marked "External (SSO)" and read-only (password-change hidden client-side, `PUT /password/:username` rejects with 403 server-side). Redis user-backend only.

##### Changed
- All pages now wrap their content in a standard-width container, matching sso-manager-node instead of rendering full-bleed.
- Users and Permissions pages converted from bare `<table>`s to the card-grid convention already used on the Groups page.

#### jump-host — [v1.10.2](https://github.com/theta42/jump-host/releases/tag/v1.10.2)

##### Changed
- Dashboard, Sessions, and Audit pages now match sso-manager-node/proxy's page width.
- Audit's nav entry is now admin-gated (`groups: ['admin']`).

### Bumped
- sso-manager-node -> [v1.9.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.9.0)
- proxy -> [v1.8.0](https://github.com/theta42/proxy/releases/tag/v1.8.0)
- jump-host -> [v1.10.2](https://github.com/theta42/jump-host/releases/tag/v1.10.2)
- ldap-client -> [v1.0.0](https://github.com/theta42/ldap-client/releases/tag/v1.0.0) (new submodule)

## [1.18.0] - 2026-07-28

### Changed
Cross-app API-token self-service UI unification: all 3 apps now share the
same card-grid list, "+ New Token" modal-based create flow, `app.modal`-based
secret reveal, and Edit modal (with real created-by/on audit metadata).

#### sso-manager-node — [v1.8.2](https://github.com/theta42/sso-manager-node/releases/tag/v1.8.2), [v1.8.3](https://github.com/theta42/sso-manager-node/releases/tag/v1.8.3)

**v1.8.2**

##### Fixed
- **Creating a new OAuth integration didn't reliably show the "save this client secret now" reveal modal** — `saveResource()` called `app.modal.close()` immediately before conditionally showing the secret via `app.modal.open()`. `app.modal` is a singleton, and `close()` immediately followed by `open()` collides with Bootstrap's hide-transition guard. An intervening `await loadResources()` made this race unlikely to lose in practice, but not guaranteed to — found while fixing the same, guaranteed-to-lose bug in jump-host and proxy's API-token create flows.

**v1.8.3**

##### Changed
- **`profile.ejs`'s self-service API-token UI unified onto `app.modal`**, matching the pattern already shipped this round in `directory.ejs`, proxy, and jump-host: the static `#secretModal`/`#editModal` elements are retired in favor of the shared `app.modal` singleton, the always-visible inline create-form card becomes a "+ New Token" button + modal, and badge classes switch from `bg-*` to `text-bg-*`.
- Checkmark-flash copy feedback (silently broken by FontAwesome's `<i>`→`<svg>` replacement) replaced with toast-based `copyFieldValue`, matching proxy and jump-host.

#### proxy — [v1.7.0](https://github.com/theta42/proxy/releases/tag/v1.7.0)

##### Added
- **API tokens: "+ New Token" modal button (replacing the always-visible inline create-form card) and a new Edit modal** — continues the cross-app API-token UI unification started in jump-host. The Edit modal's footer shows real created-by/on data; the `PUT /api-token/:id` route already fully supported editing, so no backend change was needed.

##### Fixed
- **Creating an API token didn't show the "save this secret now" reveal modal** — the create flow called `app.modal.close()` immediately before `app.modal.open()` (to show the secret) in the same tick; since `app.modal` is a singleton, that collided with Bootstrap's hide-transition guard and the reveal modal silently never appeared.

#### jump-host — [v1.10.0](https://github.com/theta42/jump-host/releases/tag/v1.10.0), [v1.10.1](https://github.com/theta42/jump-host/releases/tag/v1.10.1)

**v1.10.0**

##### Added
- **API-token UI unified with sso-manager-node/proxy**: card grid replacing the bare table, a new Edit modal (footer shows real created-by/on data), and a Description field on both the create and edit flows — the model and API already fully supported all of this, it just wasn't exposed anywhere in the dashboard.

##### Changed
- `@simpleworkjs/frontend` bumped to `^0.2.6` (this app was still on `^0.2.5`).

**v1.10.1**

##### Fixed
- **The API-token reveal modal silently didn't show after creating a token** — `submitApiToken()` called `app.modal.close()` immediately before `showToken()`'s `app.modal.open()` in the same tick, colliding with Bootstrap's hide-transition guard on the singleton modal. Same root cause as the OAuth-secret-reveal race fixed in sso-manager-node (v1.8.2) and the create-token race fixed in proxy (v1.7.0).

### Bumped
- sso-manager-node -> [v1.8.3](https://github.com/theta42/sso-manager-node/releases/tag/v1.8.3)
- proxy -> [v1.7.0](https://github.com/theta42/proxy/releases/tag/v1.7.0)
- jump-host -> [v1.10.1](https://github.com/theta42/jump-host/releases/tag/v1.10.1)

## [1.17.0] - 2026-07-28

### Added
- **proxy's host modal now has a footer (created/updated-by/on metadata) and a linkable `/hosts/{host}` URL**, migrated onto the same shared `app.modal` component as sso-manager-node's resource modal — continuing the entity-modal standardization across the stack.

### Fixed
- **proxy: the Let's-Encrypt challenge-type/wildcard-matching visibility logic could stop reacting to the hostname field after the first Add/Edit host**, and **the SSO allow-list autocomplete could go empty starting on the second Add/Edit** — both were DOM-rebuild timing bugs in the same class as the resource-modal fixes already shipped.
- **sso-manager-node: the resource modal's "Associated LDAP Groups" autocomplete went empty after the first Add/Edit** — same DOM-rebuild timing bug, now fixed.

### Bumped
- sso-manager-node -> [v1.8.1](https://github.com/theta42/sso-manager-node/releases/tag/v1.8.1)
- proxy -> [v1.6.0](https://github.com/theta42/proxy/releases/tag/v1.6.0)

## [1.16.0] - 2026-07-28

### Added
- **"Quick Jump" copy-to-clipboard section on the jump-host dashboard** — one-click-copy SSH commands (interactive-picker mode, plus a per-host `uid_-_target` grammar-mode command) instead of having to remember/reconstruct the format by hand.

### Fixed
- **jump-host audit records for a failed downstream connection only ever said `upstream-unreachable`**, with no way to tell a network-layer failure from an auth failure — the real error (ECONNREFUSED, ETIMEDOUT, an ssh2 auth-failure message, etc.) is now captured and shown as a tooltip on the audit table's fail badge.

### Bumped
- jump-host -> [v1.9.0](https://github.com/theta42/jump-host/releases/tag/v1.9.0)

## [1.15.0] - 2026-07-28

### Fixed
- **sso-manager's Directory data (every site/host/service/oauth-client resource and their relationships/LDAP-group associations) had no persistent volume** — `@simpleworkjs/orm` fell back to `./config/inventory.sqlite` (relative to the app's `/app` cwd) whenever `conf.orm` wasn't set, which sits in the container's ephemeral writable layer, not any mounted volume. Every container recreate (`docker compose up --build`, `down`/`up`, an image rebuild) silently wiped the entire Directory Management page. `setup.sh`'s generated `sso-secrets.js` (and the example template) now set `orm: { dialect: 'sqlite', storage: '/data/inventory.sqlite' }`, co-locating it with the already-persisted `sso-data` volume (where Redis lives). **Existing deployments**: this repo doesn't rewrite an operator's existing `config/sso-secrets.js` (re-running `setup.sh` leaves it untouched by design) — add the `orm` block above manually, and copy the container's current `/app/config/inventory.sqlite` to `/data/inventory.sqlite` *before* recreating the container, or the existing Directory data will be lost on the next recreate instead of migrated.

### Bumped
- sso-manager-node -> [v1.8.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.8.0)

## [1.14.0] - 2026-07-28

### Fixed
- **jump-host's Redis had zero persistence** (`--save '' --appendonly no`, no data-dir volume) — every container rebuild/recreation (including a `setup.sh` re-run) silently wiped all sessions, in-flight OAuth logins, and any admin-created API token. This is the root cause of the reported "re-running setup.sh breaks OAuth with jump" — the jump-host container gets recreated, and any token or in-flight login vanished with it, while proxy was unaffected because its Redis was already persisted. Now jump-host's Redis persists (AOF + periodic RDB) to `/data`, mounted as a new named volume, `jump-redis-data`. Verified live: minted a PAT, force-recreated the container, confirmed the same PAT still authenticated afterward.

### Changed
- `docker-compose.yml`: added the `jump-redis-data` volume, mounted at `/data` on the `jump-host` service.

### Bumped
- jump-host -> [v1.8.1](https://github.com/theta42/jump-host/releases/tag/v1.8.1)

## [1.13.0] - 2026-07-28

### Fixed
Found via feedback on a fresh install:
- **jump-host's OAuth client had no parent in the Directory.** `seedDirectory()` only ever linked the proxy's OAuth client; jump-host's own (minted by `provisionJumpHost`) was created but never passed through, so it never got a `ResourceEdge`. Existing deployments self-heal on the next `setup.sh` run.
- **TUI-mode SSH connections (bare `ssh user@host`) could drop** with "PTY allocation request failed" / "shell request failed" — a session-listener race in jump-host, same class of bug `runGrammar` already had a fix for.
- **Every form submit briefly showed literal HTML** instead of a loading spinner, across all three apps.
- **`POST /api/user/` and `PUT /api/user/password` had no success message** — a green notification with nothing in it right after adding a user.
- **The login page gave no explanation for why the user landed there** when redirected mid-OAuth-flow.

### Changed
- **Directory: tree view is now the only view; clicking a resource's name opens its detail modal.**

### Bumped
- sso-manager-node -> [v1.7.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.7.0)
- proxy -> [v1.5.3](https://github.com/theta42/proxy/releases/tag/v1.5.3)
- jump-host -> [v1.8.0](https://github.com/theta42/jump-host/releases/tag/v1.8.0)

No `setup.sh` or compose change. Also confirmed (no fix needed): the Let's Encrypt ACME account key persists correctly across container rebuilds — `lua-resty-auto-ssl`'s Redis storage adapter writes through the bundled Redis, which is started with `--appendonly yes` into `/data`, mapped to the persisted `proxy-data` volume. Only an explicit `docker-compose down -v` / volume removal would lose it (which is also what's required, and expected, on a domain change).

## [1.12.0] - 2026-07-28

### Bumped
- sso-manager-node -> [v1.6.3](https://github.com/theta42/sso-manager-node/releases/tag/v1.6.3) — fixes the root cause of a real "lost user" report: `routes/group.js` never invalidated the User cache on membership changes, so an account added to the `app_sso_service_account` marker group (which hides accounts from the Users page's People tab) could look like it had vanished for up to 5 minutes — and, separately, could be added to that group with no warning at all. Both fixed; see the linked release for detail.

No `setup.sh` or compose change.

## [1.11.0] - 2026-07-28

### Added
- **`test/check_jump_ldap_tls.js`**, wired into the `Lint` workflow: a static consistency check on the jump-secrets.js template `bootstrap.js` generates, so the `ldap://` + `tlsOptions` mistake that broke every SSH login in 1.10.0 fails CI before it ever reaches a real deployment again.
- **A static "no native `alert()`/`confirm()`/`prompt()`" check** is now part of all three apps' own test suites (they block all further browser events on the page — see 1.9.0/1.10.0's release notes).

### Bumped
- sso-manager-node -> [v1.6.2](https://github.com/theta42/sso-manager-node/releases/tag/v1.6.2) — fixes `DELETE /api/oauth/client/:id` (`client.remove is not a function`, a genuine 500 masked by tests that never checked the response status), plus the regression test above.
- proxy -> [v1.5.2](https://github.com/theta42/proxy/releases/tag/v1.5.2) — the regression test above.
- jump-host -> [v1.7.1](https://github.com/theta42/jump-host/releases/tag/v1.7.1) — the regression test above.

No `setup.sh` or compose change.

## [1.10.0] - 2026-07-27

### Fixed
- **`bootstrap/bootstrap.js`'s jump-secrets.js template now points jump-host at `ldaps://sso-manager:636`**, not `ldap://sso-manager:389`. The plain-port URL combined with jump-host's `tlsOptions` made `ldapts` attempt implicit TLS against a port serving plaintext LDAP — slapd dropped every connection before any LDAP message parsed, so SSH password login failed for every account, with any password, indistinguishable from a wrong credential. Root-caused by standing up a local jump-host, editing its config, and calling `getUser`/`checkPassword` directly inside the container. **Existing deployments must edit `./config/jump-secrets.js` themselves** (this template only affects fresh bootstraps) — see theta42/theta-suite#99. Companion defensive fix: [simpleworkjs/ldap v1.0.2](https://github.com/simpleworkjs/ldap/releases/tag/v1.0.2) now rejects this `ldap://` + `tlsOptions` combination outright.

### Bumped
- jump-host -> [v1.7.0](https://github.com/theta42/jump-host/releases/tag/v1.7.0) — adds self-service API tokens (create/list/rotate/revoke from its dashboard); jump-host previously had none.

No `setup.sh` or compose change.

## [1.9.0] - 2026-07-27

### Bumped
- sso-manager-node -> [v1.6.1](https://github.com/theta42/sso-manager-node/releases/tag/v1.6.1)
- proxy -> [v1.5.1](https://github.com/theta42/proxy/releases/tag/v1.5.1)

Both apps had every native `alert()`/`confirm()` call removed, replaced by
`@simpleworkjs/frontend`'s `app.messages.action`/`confirm`/`toast` (the
same modules adopted in [1.8.0](#180---2026-07-27)). This was found live,
mid browser-verification of that release: clicking sso-manager-node
directory.ejs's "Rotate Client Secret" triggered a native `confirm()`,
which blocks all further browser events on the page — a real hazard for
anyone driving the app with browser automation, not just a cosmetic
inconsistency. sso-manager-node also dropped `app.user.remove`/
`app.oauthClient.remove` from `public/js/app.js` (dead code with a native
`confirm()` guard and zero callers).

No `setup.sh`, compose, or config change.

## [1.8.0] - 2026-07-27

### Bumped
- sso-manager-node -> [v1.6.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.6.0)
- proxy -> [v1.5.0](https://github.com/theta42/proxy/releases/tag/v1.5.0)
- jump-host -> [v1.6.0](https://github.com/theta42/jump-host/releases/tag/v1.6.0)

All three apps adopt the newly published `@simpleworkjs/frontend` package's
`app.messages`, `app.modal`, and `app.validate` modules, replacing the
vendored `app.util.actionMessage`/`actionConfirm`/`alert` in
`public/lib/js/app-base.js` (byte-identical across all three apps) and the
vendored `public/lib/js/val.js` (byte-identical in sso-manager-node and
jump-host, and the same engine plus proxy-only DNS/hostname rules in proxy).
Message content is now HTML-escaped — the ad hoc `app.util.alert()` this
replaces had none — and `app.messages.action` falls back to a page-wide
toast when there's no inline `.actionMessage` target on the page. proxy's
`host`/`target`/`hostname` wildcard-DNS validation rules (mirroring
`utils/hostname_validate.js`) move to its own `public/js/app.js`, registered
via `$.validateSettings`, since they're proxy-specific and don't belong in
the shared package's generic rule set (`eq`/`user`/`password`/`ip`).
jump-host doesn't currently use any `[validate]` attributes, so its `val.js`
swap is dedup/future-proofing rather than a behavior change.

`app.api`/`app.auth`/`app.pubsub`/`app.socket` in each app's `app-base.js`
are untouched: they're app-specific (a dual-mode callback/promise API with
`auth-token` header injection) and not something the frontend package's
generic `app.js` provides, so it isn't loaded.

No `setup.sh`, compose, or config change.

## [1.7.0] - 2026-07-27

### Bumped
- sso-manager-node -> [v1.5.1](https://github.com/theta42/sso-manager-node/releases/tag/v1.5.1)
- jump-host -> [v1.5.0](https://github.com/theta42/jump-host/releases/tag/v1.5.0)

Two production bugs fixed: `PUT /api/user/:uid` 500'd with an LDAP
`ObjectClassViolationError` when setting `sshPublicKey` on any account
predating the `ldapPublicKey` objectClass (notably the bootstrap admin) —
and the exact same bug, in the shared `@simpleworkjs/ldap` package's
`addSshKey`, was silently aborting SSH connections at jump-host's
key-injection step for the same class of accounts. Both are fixed by
ensuring the objectClass is present before writing the attribute. Also
fixed: the Directory's "add resource" modal left the parent-Service
dropdown blank when adding an OAuth Integration.

Jump-host's web dashboard also gained a "Hosts you can reach" list
(admins see "All hosts") — previously it only showed usage metrics with
no way to see your actual access from the browser.

No `setup.sh`, compose, or config change.

## [1.6.0] - 2026-07-26

### Bumped
- jump-host -> [v1.4.0](https://github.com/theta42/jump-host/releases/tag/v1.4.0)

Jump-host gains **standalone mode**: it can now run with no LDAP directory and
no SSO Manager at all, storing users and hosts itself via
`@simpleworkjs/orm` (Sequelize; SQLite by default, any Sequelize-supported
dialect). This is an app-internal capability, opt-in via
`standalone.enabled` in jump-host's own config — the bundled theta-suite stack
is unaffected and continues to wire jump-host to the shared LDAP directory
and SSO Manager as before. Two bugs were also fixed in jump-host's SSH
server: an ephemeral listen port (`0`) was silently overridden back to the
default, and session listeners could miss a client's immediate `exec`/`shell`
request.

No `setup.sh`, compose, or config change on the theta-suite side.

## [1.5.0] - 2026-07-26

### Bumped
- sso-manager-node -> [v1.5.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.5.0)
- proxy -> [v1.4.0](https://github.com/theta42/proxy/releases/tag/v1.4.0)
- jump-host -> [v1.3.0](https://github.com/theta42/jump-host/releases/tag/v1.3.0)

This release finishes the UI half of the unification that 1.4.0 deferred: the
three apps now share one front-end shell. `views/top.ejs`, `views/bottom.ejs`
and `public/lib/js/app-base.js` are byte-identical across sso-manager-node,
proxy and jump-host, and everything per-app moved into each repo's new
`nodejs/utils/ui.js` (nav items and the groups that may see them, footer links,
favicon, profile/logout targets, update-banner on/off). Nav gating is one model
everywhere — the shell reveals `.group-required-<cn>` from `GET /api/user/me`,
normalising sso's LDAP DNs and the OIDC clients' group CNs to the same shape,
with the clients' `isAdmin` flag exposed as a synthetic `admin` group. jQuery is
4.0.0 and EJS 3.1.10 in all three.

Five client-side bugs were fixed along the way, including two that broke real
flows: `app.api.delete` ignored the callback that `formAJAX` passes (so
DELETE-method forms — the proxy's host and DNS delete buttons — never refreshed),
and the login page threw on every logged-out visit while revealing its card.

No `setup.sh`, compose or config change: this is app-internal UI work. Verified
by driving a full stack of all three apps in a browser — every page renders
console-clean, nav gating is correct per role, and the OIDC login round trip
completes on both OIDC clients.

sso-manager-node 1.5.0:

### Changed
- **Unified the front-end UI shell across the three theta42 apps.** `views/top.ejs`, `views/bottom.ejs` and `public/lib/js/app-base.js` are now byte-identical in sso-manager-node, proxy and jump-host, so the apps look and behave the same and a shell change lands in one edit per repo instead of three divergent ones. Everything that differs between the apps moved into a new `nodejs/utils/ui.js`, exposed to every render as `ui` via `app.locals`: nav items and the groups that may see them, footer repo/license/docs/Terms links, favicon, the profile and post-logout targets, and whether the update banner exists at all.
- **One nav-gating model everywhere.** `app-base.js` reveals `.group-required-<cn>` elements for each group the current user is in, read from `GET /api/user/me`. sso-manager-node reports LDAP DNs in `memberOf` and the OIDC clients report CNs in `groups`; both normalise to CNs client-side, and the clients' effective-rights `isAdmin` flag is exposed as a synthetic `admin` group — so one gating model covers a group-based provider and boolean-admin clients without either app learning the other's response shape.
- **`GET /api/user/me` is fetched once per page load and cached** (`app.auth.loadUser`). The nav, per-view `forceLogin` and every group-gated element read that one promise instead of issuing their own request.
- `app.auth.isLoggedIn` is dual-mode: it returns a Promise **and** invokes an optional node-style callback, so the async and callback call styles both work against one shared `top.ejs`.
- `app.auth.forceLogin` no longer uses `$.holdReady` (removed in jQuery 4). An unauthenticated user is redirected to `/login?redirect=<path>`; group requirements are still enforced, and `logOut` now only clears the session, leaving the destination to the caller (`ui.logoutRedirect`).
- Dependency alignment across all three apps: `jquery` `^4.0.0` and `ejs` `^3.1.10`.

### Fixed
- **`app.api.delete` dropped its callback when called by `formAJAX`.** `formAJAX` always passes the serialized form as the second argument, so a DELETE-method form's callback landed in the data slot and never ran. `delete` now accepts both `(url, callback)` and `(url, data, callback)`.
- **`app.api.post`/`put` referenced an undefined `callback2`** and threw when handed a non-function callback. Both are now dual-mode Promise/callback.
- **The login page's "reveal the card once we know you're logged out" branch threw** (`Cannot read properties of null`) whenever the logged-in check answered before the parser reached that element — which it always did without a stored token. It now runs on DOM ready.
- **`logInRedirect` on the legacy `/login/<path>` form kept only the path.** The OIDC provider routes an unauthenticated authorization request through `/login/oauth/authorize?client_id=…&state=…`; dropping the query there loses the entire authorization request. The suffix form now preserves its query string.

### Fixed (sso-manager-node)
- `public/lib/js/val.js` shadowed `message` with `let` inside `validateField`, so a custom rule's return value never reached `validateMessage` and the caller always saw the generic length message. Resolved by adopting the shared validator, which also brings the `target`/`hostname` rules and the real password policy (>= 8 chars, and either 12+ or 3 of 4 character classes) to this app.
- `public/js/app.js` used `$.isFunction`, removed in jQuery 4.

### Added (sso-manager-node)
- `GET /api/user/me` now also reports `isAdmin` (membership in `app_sso_admin`), the single effective-rights flag the shared UI shell gates the update banner on. Group-level gating still reads `memberOf`.

### Verified
- Browser-verified against a full theta-suite stack (sso-manager + proxy + jump-host): every top-level page renders with a clean console; nav gating is correct for admin and non-admin; `forceLogin`'s onboarding and group gates fire; `val.js` blocks a weak password and accepts a strong one through a real form submit; the DELETE-method forms work; and the OIDC login round trip (authorize with PKCE -> login -> consent -> callback -> token fragment) completes on both OIDC clients.

proxy 1.4.0:

### Changed
- **Unified the front-end UI shell across the three theta42 apps.** `views/top.ejs`, `views/bottom.ejs` and `public/lib/js/app-base.js` are now byte-identical in sso-manager-node, proxy and jump-host, so the apps look and behave the same and a shell change lands in one edit per repo instead of three divergent ones. Everything that differs between the apps moved into a new `nodejs/utils/ui.js`, exposed to every render as `ui` via `app.locals`: nav items and the groups that may see them, footer repo/license/docs/Terms links, favicon, the profile and post-logout targets, and whether the update banner exists at all.
- **One nav-gating model everywhere.** `app-base.js` reveals `.group-required-<cn>` elements for each group the current user is in, read from `GET /api/user/me`. sso-manager-node reports LDAP DNs in `memberOf` and the OIDC clients report CNs in `groups`; both normalise to CNs client-side, and the clients' effective-rights `isAdmin` flag is exposed as a synthetic `admin` group — so one gating model covers a group-based provider and boolean-admin clients without either app learning the other's response shape.
- **`GET /api/user/me` is fetched once per page load and cached** (`app.auth.loadUser`). The nav, per-view `forceLogin` and every group-gated element read that one promise instead of issuing their own request.
- `app.auth.isLoggedIn` is dual-mode: it returns a Promise **and** invokes an optional node-style callback, so the async and callback call styles both work against one shared `top.ejs`.
- `app.auth.forceLogin` no longer uses `$.holdReady` (removed in jQuery 4). An unauthenticated user is redirected to `/login?redirect=<path>`; group requirements are still enforced, and `logOut` now only clears the session, leaving the destination to the caller (`ui.logoutRedirect`).
- Dependency alignment across all three apps: `jquery` `^4.0.0` and `ejs` `^3.1.10`.

### Fixed
- **`app.api.delete` dropped its callback when called by `formAJAX`.** `formAJAX` always passes the serialized form as the second argument, so a DELETE-method form's callback landed in the data slot and never ran. `delete` now accepts both `(url, callback)` and `(url, data, callback)`.
- **`app.api.post`/`put` referenced an undefined `callback2`** and threw when handed a non-function callback. Both are now dual-mode Promise/callback.
- **The login page's "reveal the card once we know you're logged out" branch threw** (`Cannot read properties of null`) whenever the logged-in check answered before the parser reached that element — which it always did without a stored token. It now runs on DOM ready.
- **`logInRedirect` on the legacy `/login/<path>` form kept only the path.** The OIDC provider routes an unauthenticated authorization request through `/login/oauth/authorize?client_id=…&state=…`; dropping the query there loses the entire authorization request. The suffix form now preserves its query string.

### Added
- `.group-required { display: none }` in `public/css/styles.css`, the base rule the shared gating model reveals against.
- Admin-only nav items lost their inline `display: none` in favour of that class, and the brand link points at `/` instead of `#`.

### Verified
- Browser-verified against a full theta-suite stack (sso-manager + proxy + jump-host): every top-level page renders with a clean console; nav gating is correct for admin and non-admin; `forceLogin`'s onboarding and group gates fire; `val.js` blocks a weak password and accepts a strong one through a real form submit; the DELETE-method forms work; and the OIDC login round trip (authorize with PKCE -> login -> consent -> callback -> token fragment) completes on both OIDC clients.

jump-host 1.3.0:

### Changed
- **Unified the front-end UI shell across the three theta42 apps.** `views/top.ejs`, `views/bottom.ejs` and `public/lib/js/app-base.js` are now byte-identical in sso-manager-node, proxy and jump-host, so the apps look and behave the same and a shell change lands in one edit per repo instead of three divergent ones. Everything that differs between the apps moved into a new `nodejs/utils/ui.js`, exposed to every render as `ui` via `app.locals`: nav items and the groups that may see them, footer repo/license/docs/Terms links, favicon, the profile and post-logout targets, and whether the update banner exists at all.
- **One nav-gating model everywhere.** `app-base.js` reveals `.group-required-<cn>` elements for each group the current user is in, read from `GET /api/user/me`. sso-manager-node reports LDAP DNs in `memberOf` and the OIDC clients report CNs in `groups`; both normalise to CNs client-side, and the clients' effective-rights `isAdmin` flag is exposed as a synthetic `admin` group — so one gating model covers a group-based provider and boolean-admin clients without either app learning the other's response shape.
- **`GET /api/user/me` is fetched once per page load and cached** (`app.auth.loadUser`). The nav, per-view `forceLogin` and every group-gated element read that one promise instead of issuing their own request.
- `app.auth.isLoggedIn` is dual-mode: it returns a Promise **and** invokes an optional node-style callback, so the async and callback call styles both work against one shared `top.ejs`.
- `app.auth.forceLogin` no longer uses `$.holdReady` (removed in jQuery 4). An unauthenticated user is redirected to `/login?redirect=<path>`; group requirements are still enforced, and `logOut` now only clears the session, leaving the destination to the caller (`ui.logoutRedirect`).
- Dependency alignment across all three apps: `jquery` `^4.0.0` and `ejs` `^3.1.10`.

### Fixed
- **`app.api.delete` dropped its callback when called by `formAJAX`.** `formAJAX` always passes the serialized form as the second argument, so a DELETE-method form's callback landed in the data slot and never ran. `delete` now accepts both `(url, callback)` and `(url, data, callback)`.
- **`app.api.post`/`put` referenced an undefined `callback2`** and threw when handed a non-function callback. Both are now dual-mode Promise/callback.
- **The login page's "reveal the card once we know you're logged out" branch threw** (`Cannot read properties of null`) whenever the logged-in check answered before the parser reached that element — which it always did without a stored token. It now runs on DOM ready.
- **`logInRedirect` on the legacy `/login/<path>` form kept only the path.** The OIDC provider routes an unauthenticated authorization request through `/login/oauth/authorize?client_id=…&state=…`; dropping the query there loses the entire authorization request. The suffix form now preserves its query string.

### Added
- `.group-required { display: none }` in `public/css/styles.css`, the base rule the shared gating model reveals against.
- `#spa-shell` dropped its inline `margin-top`; `styles.css` already sets it and the shared shell adjusts it when a banner is shown.

### Verified
- Browser-verified against a full theta-suite stack (sso-manager + proxy + jump-host): every top-level page renders with a clean console; nav gating is correct for admin and non-admin; `forceLogin`'s onboarding and group gates fire; `val.js` blocks a weak password and accepts a strong one through a real form submit; the DELETE-method forms work; and the OIDC login round trip (authorize with PKCE -> login -> consent -> callback -> token fragment) completes on both OIDC clients.

## [1.4.0] - 2026-07-25

### Bumped
- sso-manager-node -> [v1.4.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.4.0)
- proxy -> [v1.3.0](https://github.com/theta42/proxy/releases/tag/v1.3.0)
- jump-host -> [v1.2.0](https://github.com/theta42/jump-host/releases/tag/v1.2.0)

This release unifies the three theta42 apps onto shared `@simpleworkjs/*` packages
(`oidc-client`, `directory-schema`, `ldap`, `app-stack` — published under the
simpleworkjs org at 1.0.0), replacing each app's byte-identical forks of the same
code so they share one codebase and API schema. It also fixes a security
regression in the SSO directory discovery API (OAuth `client_secret_hash` leaked
to every authenticated caller) and the envelope drift that broke jump-host
bridging. The shared UI chrome (`top.ejs`/`bottom.ejs`, `app-base.js`, `val.js`)
is intentionally **not** unified in this release — that work is deferred to a
browser-verified session; see `UI_UNIFICATION_HANDOFF.md`. No `setup.sh` change:
the new `@simpleworkjs/*` deps resolve from npm inside each app's image build
(`npm ci` stays clean; no `file:`/`link:`).

sso-manager-node 1.4.0:

### Security
- **The directory discovery API leaked OAuth `client_secret_hash` (and any secret-ish metadata key) to every authenticated caller.** `Resource` doesn't override `toJSON`, so the ORM serialized `metadata` wholesale — including the `client_secret_hash` stored on `kind:'oauth'` resources — across `GET /api/discovery/resources`, `/graph`, `/me`, `/resources/:slug`, and the directory-admin `GET /api/directory-admin/resources`. Every discovery read endpoint and the admin list now route through `projectResource`/`projectResources` from `@simpleworkjs/directory-schema`, which unconditionally strips secret keys (anything matching `/secret|password|privatekey/i`, including `client_secret_hash`) and, for non-directory-admins, reduces metadata to a public allowlist. Admins never receive `client_secret_hash` either.

### Fixed
- **Directory discovery envelope drift.** `routes/discovery.js` (the `autoRouter(Resource)` mounted live at `app.js:87`) returned **bare arrays**, not the `{ results: [...] }` envelope the directory contract specifies — so jump-host's `data.results || []` collapsed every per-group query to `[]` and no user could bridge. Discovery is now served by explicit `/resources`, `/resources/:slug`, `/graph`, `/me` handlers that all return the `{ results }` envelope. The dead `routes/api_discovery.js` (mounted at `app.js:112`, *after* the 404 catcher) and its mount were removed.
- `GET /api/discovery/resources?group=<cn>` now returns 200 with `{ results: [...] }` instead of 404.

### Added
- `@simpleworkjs/directory-schema` — the directory contract: the `kind` enum, `Resource`/`ResourceEdge`/`ResourceGroup` field defs, the `{ results }` envelope, the security projection (`projectResource`/`projectResources`/`isDirectoryAdmin`), and the discovery client. `models/resource.js` imports the field defs; the discovery + directory-admin routes use the projection.
- `@simpleworkjs/ldap` — `models/user_ldap.js` and `models/group_ldap.js` now take `escapeFilter`/`escapeDN` and `makeClient`/`withClient` from the shared package (via local wrappers that pass `conf`); sso keeps its rich `User.get`/`Group.get`/`User.login`/`User.addSSHkey` (posix/write-side stays app-local). sso's `makeClient` passes no `tlsOptions`, so cert validation is unchanged.
- `@simpleworkjs/app-stack` — unified `build_info` (`{buildVersion, buildHash, buildYear}`) and the `static-modules` mounting helper. `utils/build_info.js` and the static-modules loop in `routes/index.js` use the shared helpers.
- New `tests/discovery.test.js` (jest + supertest, runs under the docker harness): locks in the `{ results }` envelope on `/resources`, `/graph`, `/me`, `/resources/:slug`, the `?group=` 200-regression, and the no-`client_secret_hash`/no-secret-key guarantee for every caller.

### Changed
- Dependency alignment: `ldapts` `^8.1.2` → `^8.1.8`. The new `@simpleworkjs/*` deps resolve from the npm registry (`^1.0.0`); no `file:`/`link:` entries in the lockfile, so `npm ci` is clean in docker builds.
- `build_info` export shape changed from `{commit, version}` to `{buildVersion, buildHash, buildYear}` (the shared shape used by all three apps).

proxy 1.3.0:

### Added
- `@simpleworkjs/oidc-client` — the OIDC client (session models, auth router, OIDC utils, safe-redirect, local-admin bootstrap). Deleted the local `utils/oidc.js`, `utils/safe_redirect.js`, `models/oidc_state.js`, `models/token.js`, `models/auth.js`, `routes/auth.js`; `models/index.js` wires the factory. The per-host SSO in `routes/host_auth.js` is unchanged but consumes the shared OIDC utils.
- `@simpleworkjs/ldap` — the ldapts client + RFC 4515/4514 escaping.
- `@simpleworkjs/app-stack` — unified `build_info` (`{buildVersion, buildHash, buildYear}`) and the `static-modules` mounting helper. `utils/build_info.js` and the static-modules loop in `routes/render.js` now use the shared helpers.

### Security
- **LDAP filter injection in `User.get`.** The user lookup built its search filter by interpolating `data.username` raw into `(&(objectClass=inetOrgPerson)(uid=<username>))`. A username containing `*`, `(`, `)`, `\`, or NUL could widen or alter the filter (e.g. `*` → match-all). The filter value is now passed through `escapeFilter` from `@simpleworkjs/ldap` (RFC 4515 escaping).

### Changed
- Dependency alignment: `model-redis` `^1.5` → `^1.6.0`, `ldapts` `^8.1.2` → `^8.1.8`. The four new `@simpleworkjs/*` deps resolve from the npm registry (`^1.0.0`); no `file:`/`link:` entries in the lockfile, so `npm ci` is clean in docker builds.
- `build_info` export shape changed from `{commit, version}` to `{buildVersion, buildHash, buildYear}` (the shared shape used by all three apps). The `/health` endpoint and footer now report `buildVersion`/`buildHash`.

jump-host 1.2.0:

### Added
- `@simpleworkjs/oidc-client` — the OIDC client (session models, auth router, OIDC utils, safe-redirect, local-admin bootstrap). Deleted the local `utils/oidc.js`, `utils/safe_redirect.js`, `models/oidc_state.js`, `models/token.js`, `models/auth.js`, `routes/auth.js`; `models/index.js` wires the factory and the local-admin bootstrap.
- `@simpleworkjs/directory-schema` — the sso↔jump-host directory contract. `utils/access.js` now fetches reachable hosts through the shared `createDirectoryClient` (`getResourcesByGroup`).
- `@simpleworkjs/ldap` — `models/user_ldap.js` is now a thin wrapper over `createLdapClient`, preserving this app's loose TLS default (`rejectUnauthorized: false`) and the exact export shape.
- `@simpleworkjs/app-stack` — unified `build_info` (`{buildVersion, buildHash, buildYear}`) and the `static-modules` mounting helper. `build_info` moved from `models/` to `utils/`; `routes/render.js` uses `mountStaticModules`.

### Fixed
- **Directory envelope drift was silently treated as "no reachable hosts".** `utils/access.js` previously read `data.results || []`, so if the SSO directory ever returned a bare array (envelope drift) every per-group query collapsed to `[]` and no user could bridge. The shared client now validates the `{ results }` envelope on every call and treats an envelope violation as a failed group fetch rather than silently returning `[]`.

### Changed
- Dependency alignment: `ldapts` `^8.1.2` → `^8.1.8`, `redis` `^4.7` → `^6.1.0` (the direct `redis` dep is unused — only `model-redis` is used, which already brings `redis` ^6.1.0). The new `@simpleworkjs/*` deps resolve from the npm registry (`^1.0.0`); no `file:`/`link:` entries in the lockfile, so `npm ci` is clean in docker builds.
- `build_info` export shape changed from `{commit, version}` to `{buildVersion, buildHash, buildYear}` (the shared shape used by all three apps). The `/health` endpoint and footer now report `buildVersion`/`buildHash`.
- `app-base.js` `forceLogin`/`logInRedirect` switched to the `?redirect=` query-param convention (matching the server-side `/login?redirect=` route).

## [1.3.7] - 2026-07-23

### Added
- The bootstrap now provisions the jump host's **web-UI SSO login** when the jump host is enabled: it mints a dedicated `theta-jump` OAuth client and writes a full `oidc` block (endpoints, client id/secret, callback) plus a generated local anti-lockout admin password into `./config/jump-secrets.js`. Matches how the proxy's OIDC client is provisioned. An existing pre-OIDC `jump-secrets.js` (API token but no OIDC client) is regenerated so upgraders get SSO login. Requires jump-host ≥ v1.1.0.

## [1.3.6] - 2026-07-23

### Bumped
- sso-manager-node -> [v1.3.2](https://github.com/theta42/sso-manager-node/releases/tag/v1.3.2)

sso-manager-node 1.3.2:

### Fixed
- **OAuth client management API returned `client_id: undefined` on every GET**, which broke this stack's bootstrap: it lists the OAuth clients and rotates by the returned `client_id`, so it called `/api/oauth/client/undefined/rotate` and got a 500 — aborting `setup.sh` with `bootstrap failed` whenever `proxy-secrets.js` had no usable secret (e.g. a fresh/rotated deployment). The ORM's `toJSON()` was stripping the mapped `client_id`/`scopes`/… fields; `OAuthClient.get()` now emits them explicitly (and omits `client_secret_hash`). Unknown client ids now 404 instead of 500.

## [1.3.5] - 2026-07-23

### Added
- **Optional SSH jump host** (theta42/jump-host) as a third, opt-in submodule. Enable with `CFG_JUMP_HOST_ENABLED=true` in `setup.env`: setup.sh clones/tag-tracks the submodule and builds it behind the `jump-host` compose profile, the bootstrap mints a directory API token and writes `./config/jump-secrets.js` (LDAP admin bind so it can inject users' `sshPublicKey`), the jump host is registered as a proxy Host (its web UI) and seeded as a directory service. Users then `ssh uid_-_host@jump.<domain>` (WinSCP-friendly) or `ssh uid@jump.<domain>` for a TUI host picker; the web UI on :3002 shows audit + metrics. Off by default — existing installs are unaffected.

## [1.3.4] - 2026-07-23

### Bumped
- sso-manager-node -> [v1.3.1](https://github.com/theta42/sso-manager-node/releases/tag/v1.3.1)

sso-manager-node 1.3.1:

### Added
- The Directory documentation (`docs/directory.md`) is now surfaced: registered in-app at `/docs/directory` ("Directory & Inventory"), help-linked from the Directory page header, and linked from the docs-site index. Extended with the shared slug conventions (`site_<name>`, `host_<hostname>` — as used by ldap-client and the theta-suite seed), the automatic-registration story (theta-suite stack seeding, ldap-client Linux host enrollment), and the API surface (admin at `/api/directory-admin`, read-only graph at `/api/discovery`).

### Changed
- Direct LDAP binds are described as first-class, not "legacy", across README, DEPLOYMENT.md, docs, and the Dockerfile: Linux hosts are a primary consumer of the directory (PAM/SSSD login, LDAP-backed `sudo` via `sudoRole`, SSH public keys via openssh-lpk) — exactly what the custom schemas exist for.

### theta-suite own changes

### Added
- `CFG_SITE_NAME` in `setup.env` (right below `CFG_DOMAIN`, default `local`): names the SSO directory site the stack registers itself under — slug `site_<name>`, matching the `parentSlug` convention ldap-client-joined Linux hosts use, so they land under the same site.
- The directory seed now collects real host facts on the machine (hostname, IP, MAC of the default-route interface, OS pretty-name, kernel — same collection as `ldap-client/index.sh`) and registers the stack host as `host_<hostname>` with that metadata, plus fills in each service's internal port and git repo (`sso-manager` 3001, `proxy` 3000, `openldap` 389/636, `openresty` 443). Existing resources from the earlier seed layout (`stack-host`, domain-slug site) are adopted in place — seed metadata only fills fields the operator hasn't set, never overwrites.
- The bootstrap now seeds the SSO directory with the stack's own resources: a site (from the configured domain), a "Stack host", and the SSO Manager + Proxy services (with their public URLs in metadata), linking the proxy's auto-registered OAuth client under its service. Also seeds the two non-obvious services the stack runs: the OpenLDAP directory (advertising the `ldaps://` endpoint Linux hosts and LDAP-native apps bind to, honoring `ldap.ldapsHost`) and the OpenResty edge (the 80/443 data plane every hostname flows through, with a wildcard `https://*.<domain>` address). The Directory page is populated out of the box instead of starting empty. Idempotent — resources whose slug already exists are operator-owned and never touched, and a seed failure only warns (never fails a bring-up, e.g. against an older sso-manager image without `/api/directory`).

## [1.3.3] - 2026-07-23

### Bumped
- sso-manager-node -> [v1.3.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.3.0) (from v1.1.18; includes the intermediate v1.2.1 release)

sso-manager-node 1.3.0:

### Added
- **OAuth client management API** at `/api/oauth/client` (group `app_sso_oauth_admin`): list, create, update, delete, and rotate-secret for OAuth clients, backed by the Resource model. Accepts form-style string inputs (newline-separated `redirect_uris`/`allowed_groups`, space-separated `scopes`).
- **Dockerized test suite**: `docker-compose -f docker-compose.test.yml up --build` spins up OpenLDAP + Redis + a test-runner that seeds the test user and runs the full jest suite (174 tests) against them. `tests/globalSetup.js` honors `REDIS_URL`.

### Fixed
- Completed the model-redis → `@simpleworkjs/orm` port that shipped half-finished in 1.2.1:
  - `OtpToken.issue`/`verify` called nonexistent `find()`/`listDetail()` — every OTP login 500'd.
  - Impersonation create/revoke called nonexistent `ImpersonationToken.listDetail()` — both endpoints 500'd.
  - `OAuthClient` read `is_valid` from the Resource model, which has no such column — every client evaluated as disabled and **all `/oauth/authorize` requests were rejected with 400**. Client validity now lives in `metadata` (absent = valid).
  - `OAuthClient.add` didn't set the required-unique `Resource.slug`; clients now get a slug derived from the client name.
  - `GET /api/token/:name/:token` returned `{results: null}` with 200 for unknown tokens (orm `get()` returns null instead of throwing); now 404s.
- `User.login` returns a clean 401 instead of crashing when neither `uid` nor `username` is supplied.
- Depend on published `@simpleworkjs/orm` ^0.2.8 and `model-redis` ^1.6.0 instead of a local `file:` link that broke `npm ci` in docker builds.

### Changed
- Removed the Mobile Phone field from the user create/edit form.

sso-manager-node 1.2.1:

### Added
- **Actionable Metrics**: New real-time metrics tracking for failed logins, top IPs, and service usage per user.
- **LDAP Monitor**: Background service to parse OpenLDAP binds over port 389 and track metrics for legacy apps.
- **UI Updates**: Executive dashboard now displays actionable metrics cards instead of raw logs. User profiles show individual service usage stats to admins.
- **Directory Management**: Integrated site/host/service abstractions into directory UI and allowed associating OAuth apps directly to services.

## [1.3.2] - 2026-07-21

### Bumped
- proxy -> [v1.2.2](https://github.com/theta42/proxy/releases/tag/v1.2.2)

proxy:

### Fixed
- Multi-target load balancing (added in 1.2.0) crashed every request to a load-balanced host: `ops/nginx_conf/targetinfo.lua` required a nonexistent `resty.balancer.round_robin` module. The `lua-resty-balancer` rock actually installed provides `resty.roundrobin` instead, with a different constructor API. Fixed `targetinfo.lua` to use the real module — verified end-to-end that requests now round-robin across targets with no Lua errors.

## [1.3.1] - 2026-07-21

### Bumped
- proxy -> [v1.2.1](https://github.com/theta42/proxy/releases/tag/v1.2.1)
- sso-manager-node -> [v1.1.18](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.18)

proxy:

### Fixed
- The bootstrap anti-lockout admin account was always created as `proxyadmin2` regardless of `conf.auth.adminUsers`, while `migrations/permission_bootstrap.js` grants the global-admin permission to `conf.auth.adminUsers[0]`. If an operator customized `adminUsers` away from the default, the bootstrapped account and the permissioned account were two different (non-matching) usernames, so the anti-lockout account ended up with no admin access. `models/user_redis.js` now derives the bootstrap username from `conf.auth.adminUsers[0]` (falling back to `proxyadmin2`), matching `permission_bootstrap.js`.
- Corrected a `secrets.js.example` comment that claimed the bootstrap admin's password "defaults to the username itself" — it actually generates a random password printed to the container log on first boot.

### Changed
- Refreshed all README screenshots (hosts, per-host SSO auth, per-host basic auth) against the current UI, and added a new load-balancing screenshot for the multi-target feature.

sso-manager-node:

### Added
- N-Way Multi-Master LDAP replication: `LDAP_SERVER_ID` + `LDAP_REPLICATION_HOSTS` configure `syncrepl` peers in the bundled OpenLDAP, and a new `/sites` page (nav: **Sites**) shows each configured peer's LDAP URL and live reachability.
- A `location` property on users, editable from the profile and user-edit forms.

### Fixed
- `/sites` (added above) 500'd on every load: `views/sites.ejs` included nonexistent partials `header`/`footer` instead of this app's actual `top`/`bottom`. Fixed to match every other view.

### Changed
- Refreshed all README screenshots (dashboard, users, groups, OAuth apps) against the current UI, and added a new Sites & Replication screenshot.

### theta-suite own changes
- Refreshed `docs/images/sso-dashboard.png` and `docs/images/proxy-hosts.png` to match the submodules' updated screenshots.

## [1.1.20] - 2026-07-20

### Bumped
- proxy -> [v1.1.17](https://github.com/theta42/proxy/releases/tag/v1.1.17)

proxy:

### Fixed
- An existing single-label subdomain host (e.g. `sso.nl.wgnode.com`) could not be attached to a wildcard cert added later (e.g. `*.nl.wgnode.com`): `Host.lookUpWildcardParent()` only checked the wildcard-as-child position (the wildcard's own base domain) and missed the far more common wildcard-as-sibling case, so the edit form's "Parent Wildcard" option stayed permanently greyed out. It now checks both positions, and a regression test covers the sibling case.

## [1.1.19] - 2026-07-18

### Bumped
- sso-manager-node -> [v1.1.17](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.17)

sso-manager-node:

### Added
- `conf.ldap.ldapsHost` and `conf.ldap.ldapsPort` config options for advertising a separate, internal-only LDAPS hostname on the `/integrations` page. Falls back to the public OAuth issuer host when unset.
- Contextual help panel on `/integrations` → LDAP explaining why LDAPS needs a hostname, why port 636 should not be forwarded publicly, and the recommended internal-DNS / Docker-internal alternatives.
- Tests for the `/integrations` route's LDAPS URL derivation and `ldapsHost` override.

### Changed
- `nodejs/package.json` / `package-lock.json` version bumped to `1.1.17`.
- `routes/index.js` now derives the displayed LDAPS URL from `conf.ldap.ldapsHost`/`ldapsPort` with fallback to the OAuth issuer host.
- `docs/configuration.md`, `docs/ldap.md`, `DEPLOYMENT.md`, and `secrets.js.example` document the new `ldapsHost`/`ldapsPort` options and recommended network layouts.

### theta-suite own changes
- `setup.env.example` adds optional `CFG_LDAPS_HOST` for the internal LDAPS hostname.
- `setup.sh` passes `CFG_LDAPS_HOST` into the generated `./config/sso-secrets.js` as `ldap.ldapsHost`.
- `config.example/sso-secrets.js.example` documents `ldap.ldapsHost` / `ldap.ldapsPort`.
- `.env.example` adds `LDAPS_HOST` for legacy `.env` migrations.
- `docker-compose.yml` comments warn against forwarding 636 to the public internet.
- `README.md` explains the `CFG_LDAPS_HOST` recommendation in the port-forwarding section.

## [1.1.18] - 2026-07-18

### Bumped
- proxy -> [v1.1.16](https://github.com/theta42/proxy/releases/tag/v1.1.16)
- sso-manager-node -> [v1.1.16](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.16)

proxy:

### Changed
- Public-release packaging: removed `"private": true` from `nodejs/package.json`, corrected the repository URL to `https://github.com/theta42/proxy.git`, and fixed the MIT `LICENSE` copyright line.
- Genericized committed config defaults in `conf/base.js` and `conf/development.js` (`example.com` / `localhost` instead of theta42 infrastructure).
- The bootstrap `proxyadmin2` account now gets a random, one-time password when `auth.localAdminPass` is unset, instead of the well-known default.

### Security
- Sanitized rendered docs HTML with `xss` in `routes/docs.js`.
- The Unix socket JSON-RPC socket is now created with mode `660` instead of world-writable `777`.

### Fixed
- The global error handler no longer leaks `err.keys`, stack traces, or internal details in JSON responses.
- `DEPLOYMENT.md` and `docs/docker.md` now correctly describe the `CONF_SECRETS` env-var mechanism.

sso-manager-node:

### Security
- Hardened LDAP filter and DN construction against injection in `models/group_ldap.js` and `models/user_ldap.js`.
- Replaced `Math.random()`-based token/UUID/OTP generation with `crypto.randomUUID()` / `crypto.randomInt()` in `models/token.js`, `models/oauth_code.js`, and `models/oauth_client.js`.
- Refused startup when `oauth.jwtSecret` is missing or placeholder.
- Sanitized rendered docs/Terms-of-Service HTML with `xss` to block malicious markdown output.
- Removed full-object `console.log` of new-user data and reduced login error logging to `name`/`message` only.

### Changed
- Public-release packaging: removed `"private": true` from `nodejs/package.json` and bumped version to `1.1.16`.

### Fixed
- `models/email.js`: fixed from-address template rendering bug.

### theta-suite own changes
- `CHANGELOG.md` now embeds the full app-level release notes for each submodule bump, not just links.
- `.env.example` no longer ships realistic-looking default passwords; values are clearly placeholders.
- `config.example/*.js.example` comments now describe the actual `CONF_SECRETS` env-var loading mechanism.
- `setup.sh` summary no longer prints generated passwords to stdout; it points to `./config/*.js`.
- `bootstrap/bootstrap.js` fails hard instead of falling back to weak default passwords when config is missing.

## [1.1.17] - 2026-07-18

### Bumped
- proxy -> [v1.1.15](https://github.com/theta42/proxy/releases/tag/v1.1.15)
- sso-manager-node -> [v1.1.15](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.15)

Both apps' bare-metal `install.sh` now installs to `/opt/theta42/<app>` and seeds `/etc/<app>/secrets.js` on first run, matching a `wget -O - .../install.sh | sudo bash` one-line install for both (previously proxy-only); re-running it prints the version it's updating from/to. sso-manager-node's installer was rewritten from a flag-driven, copy-based script into the same idempotent git-clone pattern proxy already used, and now bootstraps OpenLDAP itself on first run instead of requiring the repo to already be checked out locally. None of this affects the Docker/unified-stack deployment this repo orchestrates — bare-metal-only.

## [1.1.16] - 2026-07-18

### Bumped
- proxy -> [v1.1.14](https://github.com/theta42/proxy/releases/tag/v1.1.14)
- sso-manager-node -> [v1.1.14](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.14)

Both: bumped `@simpleworkjs/conf` to 1.2.0 and `jq-repeat` to 2.2.0.

### Changed
- `./config/sso-secrets.js` and `./config/proxy-secrets.js` are now loaded via each app's `CONF_SECRETS` env var (set by the entrypoint) instead of being symlinked into `/app/conf/secrets.js` — neither container needs write access to its own `conf/` directory anymore. No change to the config file format or bind mounts; existing `./config/` directories keep working as-is.

## [1.1.15] - 2026-07-17

### Bumped
- proxy -> [v1.1.13](https://github.com/theta42/proxy/releases/tag/v1.1.13)
- sso-manager-node -> [v1.1.13](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.13)

proxy:

### Fixed
- The host edit form's "Parent Wildcard" option stayed greyed out even when a valid wildcard actually existed for that host, so an already-created host could never be switched onto one from the edit modal (only brand-new hosts, via the field's `keyup` handler, ever saw it become available). The underlying `/host/lookup/:item` check also had the same self-match issue as the recently-fixed backend bug: it resolved an already-existing host to its own record instead of a sibling wildcard. Added a dedicated `/host/wildcard-parent/:item` endpoint that checks both directions, and the edit form now actually runs the check when it opens.
- Fixed an nginx startup warning: `the "listen ... http2" directive is deprecated, use the "http2" directive instead`. Migrated to the standalone `http2 on;` directive (nginx 1.25.1+).

### Added
- Four new plain-language docs aimed at less technical readers, replacing the system-design-level Architecture/Installation docs as the target of most card help links: **Hosts & HTTPS**, **DNS Providers**, **Users, Groups & Permissions**, and **API Tokens**. Each links onward to the deeper technical reference for readers who want it; the technical docs link back the other way too. The personal-access-token card (previously missed entirely) now has a help link.

### Fixed
- The in-app docs viewer rendered every `docs/*.md` page with a garbled heading and a stray horizontal rule at the top — Jekyll front matter (meant only for the GitHub Pages build) was never stripped before being handed to the markdown renderer. Also fixed: cross-doc links never resolved in-app, since this viewer serves docs at `/docs/<slug>` with no `.html` suffix — they're now rewritten to the correct in-app URL (by registered slug, falling back to the doc's real filename), the same way image paths already were.

sso-manager-node:

### Added
- Three new plain-language docs aimed at less technical readers, replacing the schema-level LDAP/OAuth/API docs as the target of most card help links: **Accounts, Groups & Managers**, **Connecting Apps (SSO)**, and **API Tokens**. Each links onward to the deeper technical reference for readers who want it; the technical docs link back the other way too. The personal-access-token card (previously missed) now links to its own doc.

### Fixed
- The in-app docs viewer rendered every `docs/*.md` page with a garbled heading and a stray horizontal rule at the top — Jekyll front matter (meant only for the GitHub Pages build) was never stripped before being handed to the markdown renderer. Also fixed: cross-doc links (`ldap.html`, `index.html`, etc.) never resolved in-app, since this viewer serves docs at `/docs/<slug>` with no `.html` suffix — they're now rewritten to the correct in-app URL, the same way image paths already were.
- The new concept docs' cross-links (`concepts-accounts.html` etc.) are the correct, working URL on the Jekyll/GitHub Pages build (where the page's URL is its filename stem) but didn't resolve in the in-app docs viewer, which serves docs at a separate short slug (`/docs/accounts`). The in-app renderer now also resolves a doc's real filename as a fallback, so one link written in a doc works on both targets.

## [1.1.14] - 2026-07-17

### Bumped
- proxy -> [v1.1.11](https://github.com/theta42/proxy/releases/tag/v1.1.11)
- sso-manager-node -> [v1.1.11](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.11)

Both: moved the help (❓) link out of the global header and onto each relevant card individually, so it deep-links straight to the doc that actually covers that card instead of one generic per-page guess.

## [1.1.13] - 2026-07-17

### Bumped
- proxy -> [v1.1.10](https://github.com/theta42/proxy/releases/tag/v1.1.10)
- sso-manager-node -> [v1.1.10](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.10)

Both: added a help icon (❓) in the top-right header that deep-links to the doc most relevant to the current page, and made the in-app docs viewer (`/docs`) searchable (a simple line-substring search over the local doc set, no new dependency, still works with no internet access).

## [1.1.12] - 2026-07-17

### Bumped
- proxy -> [v1.1.9](https://github.com/theta42/proxy/releases/tag/v1.1.9)

proxy:

### Added
- The host list now shows who created each host, and when.
- Plain (non-wildcard) hosts can now be renamed after creation — the hostname field is no longer permanently locked. Wildcard hosts, wildcard children, and auto-created subdomain cache entries stay locked, since other records reference them by name.
- More inline help text on the host create/edit form (Target SSL, wildcard matching behavior).

### Fixed
- The host create/edit modal's tabs could overflow awkwardly on narrow (mobile) screens — they now scroll horizontally instead.
- Fixed a bug in the vendored `model-redis` library's record-rename path: renaming a record's primary key while another `always`-type field (e.g. `updated_on`) is defined earlier in the schema left a stray, incomplete hash behind under the old key, making that name permanently unavailable for reuse. Worked around in `Host.prototype.update()`.

## [1.1.11] - 2026-07-17

### Bumped
- proxy -> [v1.1.8](https://github.com/theta42/proxy/releases/tag/v1.1.8)

proxy:

### Fixed
- **Couldn't attach an existing host to a parent wildcard.** The host edit form's "Parent Wildcard" option submitted correctly, but `Host.prototype.update()` had no `challengeType` handling at all (only `Host.create()` did) — selecting it and saving silently did nothing. Added the same wildcard-parent lookup to `update()`.
- **Couldn't register a wildcard's own base domain as a host.** A wildcard cert's `altNames` already cover both the base domain and `*.base domain`, but the lookup tree stores the wildcard one level below its base domain, and a lookup for the bare base domain landed on that empty parent node and found nothing — even though the already-issued cert covers it. `buildLookUpObj()` now also stamps the parent node so this resolves correctly, without re-issuing or duplicating the cert.

## [1.1.10] - 2026-07-17

### Bumped
- sso-manager-node -> [v1.1.9](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.9)

sso-manager-node:

### Added
- Every account's personal Unix group (its primary GID holder) can now have supplementary members managed from the account's profile page ("Members of `<uid>`'s group", admin-only) — e.g. to share write access to files owned by that group. Uses the standard `memberUid` attribute (RFC 2307 `posixGroup`).

## [1.1.9] - 2026-07-17

### Bumped
- sso-manager-node -> [v1.1.8](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.8)

sso-manager-node:

### Added
- Group membership is now editable directly from a user's profile page ("My groups" -- add via a group-name picker, remove with a button per row), instead of only from each group's own card on the Groups page. Admin-only, using the existing per-group member add/remove endpoints.

### Fixed
- The Edit Profile form's Mobile Phone field had a stray `validate=":9"` making it effectively required (submission was blocked with "Please fix the form errors" if left blank) -- it was always meant to be optional, matching the "Add user" form. Removed.
- A service account's profile always showed `Name: Service Account` -- every service account has the same literal filler given/last name (a schema-satisfying placeholder, not meant to be shown), making them indistinguishable by name. The Name line is now hidden for service accounts.
- The Users page's Service Accounts tab, and a freshly-created service account's own profile, could appear empty/not-a-service-account for up to 5 minutes right after creation. Creating a user caches it via `User.get()` *before* the route handler marks it as a service account (group membership), so the cached copy had `isServiceAccount` stuck wrong until the cache TTL expired. Now cleared and re-fetched immediately after marking.
- A user belonging to exactly one LDAP group had their `memberOf` attribute returned as a bare string instead of a one-element array (ldapts's normal behavior for single-valued attributes) -- client-side permission checks (`for(let group of user.memberOf)`) would then iterate the DN character-by-character instead of once, causing pages gated on that group (e.g. Groups) to incorrectly show "You do not have permission to be here." Normalized `memberOf` to always be an array, same fix already applied to `manager`.

## [1.1.8] - 2026-07-17

### Bumped
- sso-manager-node -> [v1.1.7](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.7)

sso-manager-node:

### Changed
- **Service accounts unified to one kind.** Removed the LDAP bind-only service account type (the Integrations → LDAP "Service Accounts" card, and its `/api/service-account` routes) -- every service account is now a real Unix/POSIX account with a UID, created from the new **Users → Service Accounts** tab. Email and password are both optional for service accounts; a blank password means no `userPassword` is set at all (the account simply can't bind).
- **Added a `manager` field to every account.** Multi-valued (a list of usernames), defaults to whoever created the account (the admin who added it, or whoever sent the invite), and reassignable from the account's Edit form. Anyone listed as a manager can edit that account -- same fields an admin can (mobile, description, SSH key, date of birth, home directory, login shell, manager list) -- without needing `app_sso_admin`.
- `homeDirectory` and `loginShell` are now editable from the Edit Profile form (previously view-only).

## [1.1.7] - 2026-07-16

### Bumped
- proxy -> [v1.1.7](https://github.com/theta42/proxy/releases/tag/v1.1.7)
- sso-manager-node -> [v1.1.6](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.6)

Both: redesigned the GitHub Pages docs site to match each app's own look (dark navbar/footer, Bootstrap 5, Font Awesome) instead of the generic `jekyll-theme-cayman` theme, added a real cross-page nav, SEO (`jekyll-seo-tag` + `jekyll-sitemap`), and mobile-responsive layout. theta-suite's own docs site got the same treatment in this release too (see below).

### Changed
- theta-suite's own docs site redesigned the same way -- dark navbar/footer using the shared theta42 logo (this repo has no app UI of its own), cross-page nav, SEO, mobile-responsive. `docs/index.md`'s "More docs" section removed (redundant with the new nav).
- Added `docs/_site` to `.gitignore` (missing entirely before).

## [1.1.6] - 2026-07-16

### Bumped
- proxy -> [v1.1.6](https://github.com/theta42/proxy/releases/tag/v1.1.6)

proxy: Hosts admin UI's Authentication tab radios (Off / Basic / SSO) had no shared `name`, so clicking one didn't uncheck the others. Added `name="auth_mode"` to restore standard exclusive radio-group behavior.

## [1.1.5] - 2026-07-16

### Bumped
- proxy -> [v1.1.5](https://github.com/theta42/proxy/releases/tag/v1.1.5)
- sso-manager-node -> [v1.1.5](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.5)

Both: bumped `jq-repeat` 2.0.1 -> 2.1.0. proxy fixed real breakage from the removed `__setPut`/`__setTake` API (insert/remove row hooks in the admin UI); sso-manager-node fixed a stale-data flash in the edit-profile flow caused by `update()`'s new throttling.

## [1.1.4] - 2026-07-16

### Added
- White-label support in both proxy and sso-manager-node -- `<title>`, navbar brand, and logo are now conf-driven (`conf.name`/`conf.logo`) instead of hardcoded. Closes [proxy#45](https://github.com/theta42/proxy/issues/45) and [sso-manager-node#6](https://github.com/theta42/sso-manager-node/issues/6).

### Fixed
- sso-manager-node: the bundled default LDAP ppolicy had `pwdLockout: FALSE`, silently making "deactivate user" not actually block login. Fixed, with a drift-correction path for already-deployed instances.

### Bumped
- proxy -> [v1.1.4](https://github.com/theta42/proxy/releases/tag/v1.1.4)
- sso-manager-node -> [v1.1.4](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.4)

## [1.1.3] - 2026-07-16

### Added
- `CHANGELOG.md` (this file). Closes [#43](https://github.com/theta42/theta-suite/issues/43).

### Bumped
- proxy -> [v1.1.3](https://github.com/theta42/proxy/releases/tag/v1.1.3)
- sso-manager-node -> [v1.1.3](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.3)

## [1.1.2] - 2026-07-16

### Changed
- `docs/index.md` (the published site's home page) never linked to `architecture.md`, `quickstart.md`, or `standalone.md` — added a "More docs" section so they're reachable from the site instead of only by direct URL.

### Bumped
- proxy -> [v1.1.2](https://github.com/theta42/proxy/releases/tag/v1.1.2)
- sso-manager-node -> [v1.1.2](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.2)

## [1.1.1] - 2026-07-16

### Changed
- `setup.sh` now pins `proxy` and `sso-manager-node` to their latest release tag (`vX.Y.Z`) instead of the tip of `master`. A rebuild now always lands on a tagged, versioned release of each app rather than whatever was most recently merged upstream.

### Bumped
- proxy -> [v1.1.1](https://github.com/theta42/proxy/releases/tag/v1.1.1)
- sso-manager-node -> [v1.1.1](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.1)

## [1.1.0] - 2026-07-16

First tagged release. Establishes the `vX.Y.Z` tag convention going forward.

### Added
- `setup.sh` now reports which submodules actually moved to a newer commit during an update, instead of updating silently.

### Bumped
- proxy -> [v1.1.0](https://github.com/theta42/proxy/releases/tag/v1.1.0)
- sso-manager-node -> [v1.1.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.0)

[Unreleased]: https://github.com/theta42/theta-suite/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/theta42/theta-suite/compare/v1.3.7...v1.4.0
[1.1.17]: https://github.com/theta42/theta-suite/compare/v1.1.16...v1.1.17
[1.1.16]: https://github.com/theta42/theta-suite/compare/v1.1.15...v1.1.16
[1.1.15]: https://github.com/theta42/theta-suite/compare/v1.1.14...v1.1.15
[1.1.14]: https://github.com/theta42/theta-suite/compare/v1.1.13...v1.1.14
[1.1.13]: https://github.com/theta42/theta-suite/compare/v1.1.12...v1.1.13
[1.1.12]: https://github.com/theta42/theta-suite/compare/v1.1.11...v1.1.12
[1.1.11]: https://github.com/theta42/theta-suite/compare/v1.1.10...v1.1.11
[1.1.10]: https://github.com/theta42/theta-suite/compare/v1.1.9...v1.1.10
[1.1.9]: https://github.com/theta42/theta-suite/compare/v1.1.8...v1.1.9
[1.1.8]: https://github.com/theta42/theta-suite/compare/v1.1.7...v1.1.8
[1.1.7]: https://github.com/theta42/theta-suite/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/theta42/theta-suite/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/theta42/theta-suite/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/theta42/theta-suite/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/theta42/theta-suite/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/theta42/theta-suite/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/theta42/theta-suite/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/theta42/theta-suite/releases/tag/v1.1.0
