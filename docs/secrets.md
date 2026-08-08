---
layout: default
title: Secrets (OpenBao)
description: theta-suite's central secrets architecture — OpenBao as the single store for all app, per-user, and external-app secrets, with scoped tokens and policies.
---

# Secrets — OpenBao as the central store

theta-suite keeps **every secret in one place: [OpenBao](https://openbao.org/)**
(a Vault-community fork), running on the `theta-net` docker network at
`http://openbao:8200`. The three apps (SSO Manager, proxy, jump host) load
their boot secrets from it; end users get personal per-user secret storage
through the SSO UI; and external apps get scoped, self-contained access to
their own namespace.

This page is the operator reference. For the package API, see
[@simpleworkjs/bao-conf](https://simpleworkjs.github.io/bao-conf/).

## Why a central store

Before this, secret handling was partial and inconsistent: only the SSO read
one path from OpenBao; the proxy and jump host read bind-mounted
`./config/*-secrets.js` files; the bootstrap wrote generated OAuth creds to
those files on disk; and the SSO `/api/vault` UI was an ungated, broken
pass-through. Centralising on OpenBao gives every app the same fail-soft load
path, makes per-user secret storage possible, and lets external apps get
least-privilege access without anyone handing them the root token.

## The load path (every app)

1. `@simpleworkjs/conf` **synchronously** loads the bind-mounted
   `./config/<app>-secrets.js` at require time — the file is the operator-edit
   layer and the fail-soft fallback.
2. `@simpleworkjs/bao-conf`'s `init({ path: '<app>', conf })` **deep-merges**
   `secret/data/<app>/conf` from OpenBao over the live `conf` object. It is
   **fail-soft**: if OpenBao is unreachable or the path is absent, boot
   continues with the file-loaded config.
3. A few secrets are **captured at require time** (notably the OIDC
   `clientSecret`, consumed inside `createOidcClient` during
   `require('../models')`). So `init()` must resolve *before* that
   `require()`. Each app's `bin/www` handles this:
   - **proxy** — defers `require('../app')` (which transitively loads models)
     behind `bao-conf.init()`.
   - **jump host** — gates the explicit `require('../models')` behind
     `bao-conf.init()`.
   - **SSO** — swaps the old `conf_manager.init()` call (same position in its
     existing `.then()` boot chain) for `bao-conf.init()`; nothing in the SSO
     captures a secret at require time, so no reordering was needed.

`VAULT_TOKEN` (a scoped per-app token, **not** the root token) and
`VAULT_ADDR=http://openbao:8200` are passed to each container via
`docker-compose.yml`. The `./config/*-secrets.js` mounts stay as the fallback.

## Policies, token role, and tokens

`setup.sh` creates the ACL policies and mints the per-app tokens
(idempotently — re-running keeps existing tokens and re-mints only expired
ones). The root token stays in `.env` for setup/maintenance **only** and is
never passed to a service container.

| Policy | Capabilities | Held by |
|---|---|---|
| `sso-broker` | read/write `secret/sso-manager/conf`, `secret/users/*`, `secret/apps/*`, `secret/plugins/*`, `secret/agent/*`, `secret/data/resources/*`, `secret/metadata/resources/*`; `update` on `auth/token/create/sso-broker` + `create/sso-app` and `auth/token/renew-accessor`/`revoke-accessor`/`lookup-accessor`; `update` on `sys/policies/acl/user-*`, `app-*`, `sso-admin` | SSO (`SSO_VAULT_TOKEN`) |
| `sso-admin` | read/write/list all of `secret/*` | admin UI sessions (minted by the broker) |
| `proxy` | read `secret/proxy/conf` | proxy (`PROXY_VAULT_TOKEN`) |
| `jump-host` | read `secret/jump-host/conf` | jump host (`JUMP_VAULT_TOKEN`) |
| `user-<uid>` | read/write `secret/users/<uid>/*` | per-user tokens (minted lazily by the broker) |
| `app-<name>` | read/write `secret/apps/<name>/*` | per-external-app tokens (minted by an admin) |

## Resource Secrets & Zero-View Security Model

Directory resources (Services, Hosts, Containers, Sites) manage their application secrets at `secret/data/resources/<resource_slug>/conf` in OpenBao KV-v2.

### 1. Zero-View Security Model
* **API Metadata Only**: `GET /api/directory-admin/resources/:id/secrets` returns key names and metadata (`hasValue: true`, `isInherited: true`, `parentSlug`), but **NEVER returns raw secret values**.
* **Browser Isolation**: Secret values are never exposed in HTML DOM templates, JSON admin APIs, or browser dev tools.
* **Agent-Exclusive Delivery**: Raw secret values are fetched exclusively over TLS by authenticated `theta-agent` instances using machine authorization tokens (`POST /api/v1/agent/secrets`).

### 2. Multi-Level Hierarchy Secret Inheritance
Resources inherit secrets across any level of the directory hierarchy (`Services / Apps → Hosts / Nodes → Global Sites`):
* An inherited secret reference is stored as `INHERIT:<parent_slug>:<parent_key>` (or `INHERIT:<key>`).
* When requested by `theta-agent`, SSO Manager resolves the inheritance chain dynamically, fetching the final secret value from the parent Site or Host's OpenBao store.

### 3. Key Validation & Generator
* **Key Format**: Secret keys are strictly validated against `^[A-Za-z0-9_]+$` (Standard Environment Variable format, e.g. `DB_PASSWORD`).
* **Cryptographic Generator**: The UI includes a client-side cryptographic secret generator (`window.crypto.getRandomValues`) with length choices from 8 to 128 characters. Populating the input field displays an inline security warning notifying operators to save immediately before values are hidden.

## On-Demand CLI Secret Delivery (`theta-agent get-secret`)

`theta-agent` delivers secrets on demand directly to local processes, shell scripts, Systemd services, and Docker containers without writing plaintext secret files to disk.

```bash
# Fetch single raw secret value (stdout, no trailing newline):
theta-agent get-secret DB_PASSWORD

# Assign directly to shell environment variables:
export DB_PASSWORD=$(theta-agent get-secret DB_PASSWORD)

# Export all host/resource secrets for Systemd EnvironmentFile:
theta-agent get-secrets --env

# Format all secrets as JSON for automation scripts:
theta-agent get-secrets --json
```

**Token roles** — three, all orphan + renewable:

- `sso-broker` — `allowed_policies=sso-admin`, `allowed_policies_glob=user-*,app-*`,
  `token_period=24h`. The SSO mints per-user and per-admin tokens *through*
  this role at runtime, so it never needs the root token to issue scoped
  access. The 24h period is fine here because the broker re-mints these from
  its Redis cache transparently.
- `sso-app` — `allowed_policies_glob=app-*`, `token_period=768h`. External-app
  tokens minted from the vault UI's Apps tab go through this role: they are
  long-lived credentials, so they get a monthly period instead of a daily one.
- `theta-svc` — `allowed_policies=sso-broker,proxy,jump-host`,
  `token_period=768h`. The services' own tokens (below).

### Token lifecycle — nothing expires by surprise

Periodic tokens never hit a max TTL, but they die if nothing renews them
inside a period window. Renewal is automated at every layer:

- **Service tokens** (`SSO_VAULT_TOKEN`, `PROXY_VAULT_TOKEN`,
  `JUMP_VAULT_TOKEN`, minted via `theta-svc`, stored in `./.env`): the
  `bao-renewer` sidecar (docker-compose) renews all three every 12 hours, and
  every `setup.sh` re-run renews them too. A valid-but-non-periodic token from
  an older install is detected, revoked, and re-minted as periodic on the next
  `setup.sh` run.
- **External-app tokens** (minted in the SSO vault UI): the SSO stores each
  token's **accessor** (which can renew/revoke but not authenticate) and
  renews it every 6 hours and at boot — a downstream app's credential stays
  valid as long as the SSO is running, with no renewal code in the downstream
  app. Re-minting an app's token revokes the previous one via its accessor, so
  exactly one credential per app is ever live.
- **Per-user / admin tokens**: 24h TTL by design; the broker re-mints them
  transparently, so there is nothing to renew.

Worst case (the whole stack was down for >32 days): re-run `./setup.sh` — it
re-mints anything that lapsed; external-app tokens are re-minted from the
Apps tab (the app's policy and stored secrets are kept).

## Seeding

`setup.sh` seeds, on first run only (skipped if the path already exists):

- `secret/sso-manager/conf` — from `./config/sso-secrets.js` (operator-set
  LDAP/SMTP/`jwtSecret`; the SSO has no bootstrap-generated creds, so the file
  is the complete source of truth).
- `secret/proxy/conf` — from `./config/proxy-secrets.js` (placeholder OAuth
  creds at this point).
- `secret/jump-host/conf` — from `./config/jump-secrets.js` after the bootstrap
  writes it.

The **bootstrap** (`bootstrap/bootstrap.js`) then generates the real OAuth
client credentials and writes the *complete* `proxy-secrets.js` and
`jump-secrets.js` objects into `secret/proxy/conf` and `secret/jump-host/conf`
(POST, replacing the placeholder seed). After the first run, OpenBao is
authoritative; the `./config/*-secrets.js` files are operator-edit seed
artifacts and the fail-soft fallback.

## End-user personal secrets

Every logged-in user has a personal namespace `secret/users/<uid>/*`, reached
through the SSO UI at **Vault → My Secrets**. The SSO mints a `user-<uid>`
token on first access (cached in Redis for the token's lifetime) and proxies
`/api/vault` to OpenBao with **that** token injected server-side — the
client's SSO session token never reaches OpenBao.

- **Non-admins** see only their own namespace; the UI fixes the path prefix
  to `users/<uid>/`. They can list, read, write, and delete secrets there.
- **Admins** (`app_sso_admin` / `app_super_admin`) get free-form access across
  all of `secret/` plus an **Apps** tab (see below).

Scoping is enforced at **two** layers: the SSO's `scopeGuard` rejects any path
outside the subject's prefix with a 403 (defense-in-depth), and the token's
own OpenBao policy enforces the same at the API layer.

## External apps

An external (non-theta42) app gets scoped access to its own namespace,
`secret/apps/<name>/*`, via a token an admin mints once from the SSO UI's
**Vault → Apps** tab. The token is shown **once** (copy it immediately; it is
not stored retrievably) and confined by an `app-<name>` policy.

Convention:

- `secret/apps/<name>/conf` for config-style secrets, `secret/apps/<name>/*`
  for arbitrary keys.
- The app authenticates with the header `X-Vault-Token: <minted token>`
  against `http://<openbao-host>:8200/v1/secret/data/apps/<name>/...`.

Non-Node consumers (curl):

```bash
VAULT_ADDR=http://openbao:8200   # or your external-facing openbao address
# Write
curl -X POST "$VAULT_ADDR/v1/secret/data/apps/my-service/conf" \
  -H "X-Vault-Token: <token>" -H "Content-Type: application/json" \
  -d '{"data":{"db_password":"..."}}'
# Read
curl -s "$VAULT_ADDR/v1/secret/data/apps/my-service/conf" \
  -H "X-Vault-Token: <token>" | jq .data.data
```

Node consumers can use [@simpleworkjs/bao-conf](https://simpleworkjs.github.io/bao-conf/)
directly:

```js
const baoConf = require('@simpleworkjs/bao-conf');
const data = await baoConf.get('apps/my-service/conf'); // secret/data/apps/my-service/conf
await baoConf.set('apps/my-service/conf', { db_password: '...' });
```

## The theta-agent signing key

The SSO signs high-risk theta-agent commands (`reboot`, `configure_ldap`,
`arbitrary_bash`, …) with an Ed25519 key stored at
`secret/agent/signing-key`. Agents pin the matching public key in their
`agent.yml`, so the key **must** be stable: it used to be generated in memory at
process start, which meant it changed on every restart and no agent could
meaningfully verify anything.

If the SSO cannot read or write that path it refuses to send high-risk commands
rather than signing with a key no agent has seen — so an upgraded stack that has
not re-run `./setup.sh` (and therefore lacks `secret/agent/*` in the
`sso-broker` policy) will report `signingAvailable: false` on
`GET /api/agent/nodes` and reject those commands with a clear error.

## Plugin secrets

The SSO Manager's plugin system (configurable plugin instances you create,
edit, load/unload, and run from the **Plugins** page) stores each instance's
secrets in its own OpenBao namespace, `secret/plugins/<instance-id>/conf`,
rather than in the static `sso-secrets.js` `discovery.plugins` block. The
SSO reads and writes these server-side through the `sso-broker` token (the
plugin runs in-process as a BullMQ worker, so it needs no token of its own),
and the admin UI only ever sees masked (`********`) values.

- A **plugin type** is a module under `nodejs/plugins/<category>/<type>.js`
  exporting a manifest (`configSchema` declares which fields are `secret`).
- A **plugin instance** is a configured, loadable/unloadable copy of a type,
  tracked in the `PluginInstance` table; you can have multiple instances of the
  same type (e.g. two Proxmox endpoints with their own tokens).
- Non-secret config lives in the DB row; only the `secret:true` field values
  live in `secret/plugins/<instance-id>/conf`.

Deleting an instance removes both the DB row and its `secret/plugins/<id>/*`
namespace. Legacy `discovery.plugins` entries in `sso-secrets.js` are migrated
to instances automatically on the first boot of SSO Manager ≥ v1.17.0 (the
secret fields are copied into OpenBao at that point). See the SSO Manager
[plugins docs](https://theta42.github.io/sso-manager-node/plugins.html) for the
UI/API reference.

## Operator rotation

If a secret is exposed (or just on a routine schedule), rotate it at the
**provider** first (the LDAP server, the SMTP host, the OAuth `jwtSecret`,
etc.), then update OpenBao:

```bash
# Read the current sso-manager conf
docker exec -e BAO_TOKEN="$VAULT_TOKEN" openbao bao kv get secret/sso-manager/conf
# Write a new value (KV-v2 POST replaces the data; merge carefully)
docker exec -e BAO_TOKEN="$VAULT_TOKEN" openbao bao kv put secret/sso-manager/conf \
  ldap.bindPassword='<new>' smtp.password='<new>' oauth.jwtSecret='<new>'
```

Then restart the affected app so `bao-conf.init()` re-reads it
(`docker compose restart sso-manager`). Call-time readers pick up the change
on next read; require-time captures (OIDC `clientSecret`) need the restart.

> The SSO admin **Configuration** UI (`/api/conf`) writes `secret/sso-manager/conf`
> and updates the live conf immediately, so SMTP/discovery/oauth edits made
> there don't need a manual `bao kv put`.

## Backups

The OpenBao data volume `openbao-data` holds every secret. Back it up with the
rest of the stack (see the README's *Backups and restore* section). The
`./config/*-secrets.js` files are **not** a complete secret backup once OpenBao
is authoritative — they're the first-run seed and the fallback. A full disaster
recovery restores both the `openbao-data` volume (the authoritative store) and
`./config/` (the seed/fallback), then runs `./setup.sh` to unseal OpenBao and
re-mint the per-app tokens.

## What's not in scope yet

- **Renewal automation** — per-app/user tokens use OpenBao's default TTL and
  are re-minted by `setup.sh` on expiry; a periodic renewal worker is a
  follow-up.
- **History scrubbing** — if a secret was committed to git, rotating it is the
  fix; scrubbing it from git history (BFG / `git filter-repo`) is a separate,
  git-destructive operation you can opt into.
- **Per-app secrets beyond boot config** (e.g. the proxy's DNS-provider creds,
  the jump host's per-user LDAP SSH keys) moving into OpenBao — only the
  boot-critical `*-secrets.js` contents moved in this phase. (Plugin instance
  secrets *are* in OpenBao, at `secret/plugins/<id>/conf` — see above.)