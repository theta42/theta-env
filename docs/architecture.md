---
layout: default
title: Architecture
description: How theta-env composes the SSO Manager and proxy submodules — the OIDC/LDAP wiring setup.sh generates from one domain.
---

# Architecture

[← Back to Home](index.html)

theta-env is a **composition** repo: it builds the two existing projects from
their git submodules and adds the glue that wires them together. It does not
fork or patch them — both projects work unchanged on their own.

---

## The three repos

| Repo | Role |
|------|------|
| [`theta42/sso-manager-node`](https://github.com/theta42/sso-manager-node) | OIDC provider + OpenLDAP directory + web UI. All-in-one image (`Dockerfile.openldap`). |
| [`theta42/proxy`](https://github.com/theta42/proxy) | OIDC-protected reverse proxy (OpenResty + Node mgmt app + Redis). All-in-one image (`Dockerfile`). |
| `theta42/theta-env` (this repo) | Composes the two on one Docker network + automates first-run wiring. |

The two projects are pinned as **git submodules**. `git clone --recursive`
fetches all three in one step; `git submodule update --remote` bumps them.

---

## The two containers

```
            ┌──────────────────────────────────────────────┐
            │  your browser / apps / legacy LDAP clients     │
            └───────────────┬──────────────────────────────┘
                            │ https (:443)        ldaps (:636)
                  ┌─────────▼─────────┐
                  │  proxy container  │  OpenResty :80/:443/:4443
                  │  (OIDC + LDAP)    │  Node mgmt app :3000 (localhost only)
                  │                   │  bundled Redis (127.0.0.1:6379)
                  └─────────┬─────────┘
              ┌─────────────┼────────────────────────────┐
              │ ldaps:636   │ http:3001 (internal)       │  OIDC token + userinfo
              │ (docker net)│ (docker net, not published)│  (server-to-server)
              ▼             ▼                           │
      ┌──────────────────────────────┐                   │
      │  sso-manager container       │◄──────────────────┘
      │  OIDC provider (Express)     │  bundled Redis (127.0.0.1:6379)
      │  OpenLDAP (slapd)            │  web UI :3001 (localhost only)
      │  ldaps :636 (published)      │
      └───────────────────────────────┘
            ▲
            │ ldaps :636 (published to host) — legacy apps bind directly
            │
      ┌──────────────────────────────┐
      │  legacy apps (Gitea, Emby, …)│
      └──────────────────────────────┘
```

Both containers bundle their **own Redis** (the proxy hardcodes `127.0.0.1:6379`
in three places that ignore config; the SSO's models default to the same). Two
redis instances is the no-source-patch path and is fine at this scale.

### What's exposed, what's not

| Port | On host? | Purpose |
|------|----------|---------|
| `443` (proxy) | **yes** | the public entry point — OIDC login + proxied apps + the SSO/proxy UIs |
| `80` (proxy) | **yes** | HTTP-01 for Let's Encrypt (and redirect to 443) |
| `4443` (proxy) | yes (optional) | alt HTTPS listener |
| `3000` (proxy) | localhost only | proxy mgmt UI/API (first-run convenience; fronted by 443 normally) |
| `636` (sso) | yes | LDAPS for legacy direct-LDAP clients |
| `3001` (sso) | localhost only | SSO web UI (first-run convenience; fronted by the proxy normally) |
| `389` (sso) | **no** | plain LDAP — internal only (app↔slapd over localhost) |

---

## The first-run bootstrap

`./setup.sh` orchestrates first-run wiring; `bootstrap/bootstrap.js` does the
actual work, running **inside the sso-manager container** (bind-mounted
read-only from this repo). It's deliberately self-contained — only Node
built-ins (`child_process`, `crypto`, `fs`) + global `fetch`, and it reads its
inputs from the bind-mounted `./config/sso-secrets.js` + `./config/proxy-secrets.js`
(not from env):

1. **Build + start sso-manager**, wait for `/health`.
2. **LDAP service account** — `ldapadd` `cn=ldapclient,ou=people,<base>` (an
   `organizationalRole` with a `{SSHA512}` password). The proxy binds as this
   DN — not the admin DN.
3. **First admin user** — `ldapadd` `cn=<uid>,ou=people,<base>` (inetOrgPerson +
   posixAccount, `{SSHA512}` password) and add them as `member` of
   `app_sso_admin` + `app_sso_oauth_admin` (the SSO's permission check reads the
   group's `member` list).
4. **Log in** as that admin via `POST /api/auth/login {uid,password}` — this
   also validates the password end-to-end.
5. **Register the proxy as an OIDC client** via `POST /api/oauth/client` (gated
   by `app_sso_oauth_admin`, satisfied by step 3). The SSO **generates** the
   `client_id`/`client_secret` (UUIDs) — supplied creds are ignored — so the
   bootstrap writes the generated creds **back into `./config/proxy-secrets.js`**
   (the sso-manager mounts `./config` read-write for this; the proxy mounts it
   read-only). If `proxy-secrets.js` already holds a `clientId`+`clientSecret`
   matching an existing client, they are kept; if the client exists but the file
   has no usable secret, the secret is rotated and written back.
6. **Build + start the proxy**, wait for `/health`. The proxy entrypoint symlinks
   `./config/proxy-secrets.js` to `/app/conf/secrets.js`, so `@simpleworkjs/conf`
   (≥1.1.0) reads the OAuth creds + LDAP bind creds from the file.
7. **Register `<SSO_HOST>` and `<PROXY_HOST>` as Host records in the proxy** —
   `setup.sh` runs a short script inside the proxy container that calls its
   Host model directly (`Host.create({host, ip, targetPort, ...})`), rather
   than the proxy's own HTTP API, since no authenticated session exists yet at
   this point in the run. The proxy routes every hostname purely off a Host
   record (`ops/nginx_conf/proxy.conf` has no default/self route), so without
   this step neither URL resolves to anything. `<SSO_HOST>` targets
   `sso-manager:3001` (the Docker service), `<PROXY_HOST>` targets
   `127.0.0.1:3000` (the proxy's own management app, same container). Both
   are created with `sso_enabled: false` — each app already gates its own
   login, and SSO-gating the SSO's own login page would be circular. Skips a
   host that already exists, so re-running `setup.sh` is a no-op here.

`setup.sh` then prints the first-admin login + the public URLs.

### How config reaches the apps (no `.env`)

All config and secrets live in `./config/` (gitignored, bind-mounted). Each
entrypoint symlinks its file to `/app/conf/secrets.js` early, before the app
starts:

```
./config/sso-secrets.js    ->  sso-manager:/app/conf/secrets.js   (./config RW)
./config/proxy-secrets.js  ->  proxy:/app/conf/secrets.js         (./config RO)
```

`@simpleworkjs/conf` loads `conf/base.js → <env>.js → conf/secrets.js → app_*
env`, where **env beats `secrets.js`**. So compose passes **no `app_*` env vars**
(only `NODE_ENV`, `NODE_PORT`) — that makes `secrets.js` authoritative. The SSO
entrypoint reads the few values it needs at startup (LDAP base DN, admin
password, JWT secret, cert CN) from `secrets.js` via an in-container `node` call.

### Why not `require` the SSO's internal models?

A `docker compose exec` process reads `conf/base.js` defaults (the docker-exec
env doesn't carry the entrypoint's exported vars), so the SSO's models would
bind the wrong LDAP DN. Using the `openldap-clients` binaries with explicit
admin creds from `./config/sso-secrets.js` sidesteps that entirely, and going
through the HTTP API for the OAuth client validates the whole admin login path
end-to-end.

---

## Idempotency

Re-running `./setup.sh` converges to `./config/`:

- The LDAP service account + admin passwords are **reset to `./config/`**.
- Group membership is ensured (add is a no-op if already a member).
- The OAuth client is kept if `proxy-secrets.js` already holds its creds;
  created or rotated otherwise, and the new creds written back.

So `setup.sh` is safe to re-run after editing `./config/`, after a `docker
compose down`, or after restoring from backup.

---

## Backups and restore

`./setup.sh` auto-snapshots `./config/` + LDAP + both Redis to
`./backups/<timestamp>/` before each rebuild (keeps the last `BACKUP_KEEP`,
default 5). State lives on named volumes (`ldap-data`, `sso-data`, `proxy-data`)
and survives recreation; `down -v` wipes them. Redis is persisted with AOF +
RDB on those volumes. For the full manual-backup + restore runbook (full /
Redis-only / LDAP-only, with the AOF-vs-RDB note), see the *Backups and
restore* section of the [README](https://github.com/theta42/theta-env#backups-and-restore).
Quick LDAP backup:

```bash
docker compose exec sso-manager slapcat -f /etc/openldap/slapd.conf -b "<base>" > backup.ldif
```

[← Back to Home](index.html)