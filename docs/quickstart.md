---
layout: default
title: Quickstart
---

# Quickstart Guide

[← Back to Home](index.html)

## Prerequisites

- A Linux host with **Docker** + **Docker Compose** (the v2 plugin `docker
  compose` or the v1 standalone `docker-compose` both work).
- Two hostnames that resolve to the host: one for the SSO UI (your `stack.ssoHost`),
  one for the proxy mgmt UI (your `stack.proxyHost`). On a real network add DNS
  records; for a local try, add them to `/etc/hosts`.
- Port **80 + 443** reachable from the internet if you want Let's Encrypt
  certs; otherwise the proxy serves a self-signed fallback (browsers warn —
  expected for LAN use).

## 1. Clone

```bash
git clone --recursive https://github.com/theta42/theta-env.git
cd theta-env
```

`--recursive` fetches the two submodules (`sso-manager-node`, `proxy`) in one
step. If you forgot it:

```bash
git submodule update --init --recursive
```

## 2. Configure `setup.env` (enter your domain once)

```bash
cp setup.env.example setup.env
$EDITOR setup.env      # set CFG_DOMAIN to your domain
```

Your domain is entered **once**, as a plain DNS domain. The SSO/proxy
hostnames default to `sso.<domain>` / `proxy.<domain>`, and the LDAP base DN
is built from it (any number of labels works — a domain like
`myhost.duckdns.org` becomes `dc=myhost,dc=duckdns,dc=org`), so for most
setups `CFG_DOMAIN` is the only value you set:

| `setup.env` key | Example | Notes |
|-----|---------|-------|
| `CFG_DOMAIN` | `lab.local` | your domain — **required** |
| `CFG_SSO_HOST` | `sso.lab.local` | optional, defaults to `sso.<domain>` |
| `CFG_PROXY_HOST` | `proxy.lab.local` | optional, defaults to `proxy.<domain>` |
| `CFG_ADMIN_UID` | `admin` | optional, defaults to `admin` |
| `CFG_ADMIN_EMAIL` | `admin@<proxyHost>` | optional |
| `CFG_BASE_DN` | `dc=lab,dc=local` | advanced: override the derived LDAP base DN |

`setup.env` is used **only on the first run** to generate `./config/`; after
that `./config/*.js` are operator-owned and `setup.env` is ignored. Secrets
(LDAP admin password, JWT, admin password, service-account password) are
**generated** into `./config/*.js` on first run — do **not** put them in
`setup.env`. See `setup.env.example` for the full annotated shape, and
`config.example/` + each submodule's `secrets.js.example` for the generated
file shape.

> **Migrating from an older `.env`-based deployment?** If `.env`/`proxy.env`
> exist, `./setup.sh` migrates them into `./config/` preserving your existing
> secrets — no need to write a `setup.env`.

## 3. Run

```bash
./setup.sh
```

The first run reads `setup.env`, generates `./config/sso-secrets.js` +
`./config/proxy-secrets.js` with your domain filled in everywhere plus random
secrets, then builds and starts the stack in the same run (no edit-and-re-run).
What happens:

1. Snapshots state to `./backups/<timestamp>/` before rebuilding (a no-op on the
   very first run).
2. Builds + starts **sso-manager**, waits for `/health`.
3. Runs the **bootstrap** inside the sso-manager container — creates the LDAP
   service account, your first admin, and the proxy's OAuth client, and writes
   the generated client id + secret into `./config/proxy-secrets.js`.
4. Builds + starts **proxy**, waits for `/health`.
5. Prints your first-admin login + the public URLs.

The first run builds two Docker images (a few minutes). Subsequent runs are
fast.

## 4. Point DNS at the host

`stack.ssoHost` and `stack.proxyHost` (from `./config/sso-secrets.js`) must
resolve to the host running the stack. Add DNS records, or for a local try:

```bash
echo "127.0.0.1 sso.lab.local proxy.lab.local" | sudo tee -a /etc/hosts
```

(The proxy needs port 80 reachable for Let's Encrypt; on a LAN without that it
serves a self-signed cert — browsers will warn, which is fine for home-lab use.)

## 5. Log in

Open `https://<SSO_HOST>` and log in as your bootstrap admin
(`bootstrap.adminUid` / `bootstrap.adminPass`). From there you can add users,
groups, and OAuth clients.

The proxy mgmt UI is at `https://<PROXY_HOST>` (same admin SSO login protects
it). Add the Host records you want to protect with OIDC.

First-run fallbacks (if DNS/TLS isn't ready yet): SSO UI at
`http://127.0.0.1:3001`, proxy UI at `http://127.0.0.1:3000`.

## Re-running

`./setup.sh` is **idempotent** — safe to re-run after editing `./config/`, after
a `docker compose down`, or after restoring from backup. It snapshots state,
then converges the stack to your `./config/` values (LDAP service account + admin
passwords are reset to the config; the OAuth client is kept if `proxy-secrets.js`
already holds its creds).

## Direct LDAP for legacy apps

Legacy apps bind LDAP directly over LDAPS:

```bash
ldapsearch -x -H ldaps://<host>:636 \
  -D "cn=ldapclient,ou=people,dc=lab,dc=local" -W \
  -b "ou=people,dc=lab,dc=local" '(objectClass=posixAccount)' cn mail
```

Use the `cn=ldapclient` service account (read-only, the bootstrap created it)
or the admin DN. Use LDAPS (636), not plain LDAP.

## Backups and restore

`./setup.sh` auto-snapshots `./config/` + LDAP + both Redis to `./backups/<ts>/`
before each rebuild (keeps the last `BACKUP_KEEP`, default 5). For manual
backups and the full restore runbook (full / Redis-only / LDAP-only, with the
AOF-vs-RDB note), see the *Backups and restore* section of the
[README](https://github.com/theta42/theta-env#backups-and-restore). Quick LDAP
backup:

```bash
docker compose exec sso-manager slapcat -f /etc/openldap/slapd.conf \
  -b "<base>" > backup-$(date +%F).ldif
```

## Next steps

- Add users / groups in the SSO UI.
- Add Host records in the proxy UI to protect your apps with OIDC.
- **Mint API tokens** to drive either app's management API from scripts/CI:
  under **API Tokens** in each UI, mint a personal access token and use it as
  `Authorization: Bearer sso_…` (SSO) or `prx_…` (proxy). A token authenticates as
  its creator with their permissions. See each submodule's DEPLOYMENT.
- See [Architecture](architecture.html) for how it all fits together, and
  [Standalone](standalone.html) to run either project on its own.

[← Back to Home](index.html)