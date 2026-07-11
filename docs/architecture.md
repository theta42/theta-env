---
layout: default
title: Architecture
---

# Architecture

[← Back to Home](index.html)

theta-env is a **composition** repo: it builds the two existing projects from
their git submodules and adds the glue that wires them together. It does not
fork or patch them — both projects work unchanged on their own.

## The three repos

| Repo | Role |
|------|------|
| [`theta42/sso-manager-node`](https://github.com/theta42/sso-manager-node) | OIDC provider + OpenLDAP directory + web UI. All-in-one image (`Dockerfile.openldap`). |
| [`theta42/proxy`](https://github.com/theta42/proxy) | OIDC-protected reverse proxy (OpenResty + Node mgmt app + Redis). All-in-one image (`Dockerfile`). |
| `theta42/theta-env` (this repo) | Composes the two on one Docker network + automates first-run wiring. |

The two projects are pinned as **git submodules**. `git clone --recursive`
fetches all three in one step; `git submodule update --remote` bumps them.

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

## The first-run bootstrap

`./setup.sh` orchestrates first-run wiring; `bootstrap/bootstrap.js` does the
actual work, running **inside the sso-manager container** (bind-mounted
read-only from this repo). It's deliberately self-contained — only Node
built-ins (`child_process`, `crypto`) + global `fetch`:

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
   by `app_sso_oauth_admin`, satisfied by step 3), capturing the raw
   `client_secret` (shown once). If the client already exists and `proxy.env` is
   present, leave it; if `proxy.env` was lost, rotate the secret so a restored
   proxy gets one it can read.
6. **Write `./proxy.env`** (the proxy's `env_file`) from `.env` + the bootstrap
   output — all `app_*` env overrides so the proxy reads them via
   `@simpleworkjs/conf` (≥1.1.0).
7. **Build + start the proxy**, wait for `/health`.

`setup.sh` then prints the first-admin login + the public URLs.

### Why not `require` the SSO's internal models?

A `docker compose exec` process reads `conf/base.js` defaults (the docker-exec
env doesn't carry the entrypoint's exported `app_*` vars), so the SSO's models
would bind the wrong LDAP DN. Using the `openldap-clients` binaries with explicit
admin creds sidesteps that entirely, and going through the HTTP API for the
OAuth client validates the whole admin login path end-to-end.

## Idempotency

Re-running `./setup.sh` converges to `.env`:

- The LDAP service account + admin passwords are **reset to `.env`**.
- Group membership is ensured (add is a no-op if already a member).
- The OAuth client is left alone if `proxy.env` exists, rotated if not.

So `setup.sh` is safe to re-run after editing `.env`, after a `docker compose
down`, or after restoring from backup.

## Backups

```bash
docker compose exec sso-manager slapcat -f /etc/openldap/slapd.conf -b "$LDAP_BASE_DN" > backup.ldif
```

Keep your `.env` (holds `LDAP_ADMIN_PASS` + `JWT_SECRET`) and `proxy.env` too.
Restore is `ldapadd`/`ldapmodify` from the LDIF into a fresh directory, then
re-run `./setup.sh`.

[← Back to Home](index.html)