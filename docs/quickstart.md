---
layout: default
title: Quickstart
---

# Quickstart Guide

[← Back to Home](index.html)

## Prerequisites

- A Linux host with **Docker** + **Docker Compose** (the v2 plugin `docker
  compose` or the v1 standalone `docker-compose` both work).
- Two hostnames that resolve to the host: one for the SSO UI (`SSO_HOST`), one
  for the proxy mgmt UI (`PROXY_HOST`). On a real network add DNS records; for a
  local try, add them to `/etc/hosts`.
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

## 2. Configure `.env`

```bash
cp .env.example .env
```

Edit `.env`. The **required** values:

| Key | Example | Notes |
|-----|---------|-------|
| `LDAP_BASE_DN` | `dc=lab,dc=local` | your directory base |
| `LDAP_ADMIN_PASS` | `...` | LDAP root password — **save it** |
| `JWT_SECRET` | _(blank)_ | leave blank to auto-generate + persist — **save it** |
| `SSO_HOST` | `sso.lab.local` | hostname the proxy serves the SSO UI at |
| `PROXY_HOST` | `proxy.lab.local` | hostname the proxy serves its own UI at |
| `BOOTSTRAP_ADMIN_UID` | `admin` | your first admin login |
| `BOOTSTRAP_ADMIN_PASS` | `...` | first admin password |

Optional: `BOOTSTRAP_ADMIN_EMAIL`, `LDAP_SERVICE_PASS` (auto-generated if blank),
`SMTP_*` (for SSO password-reset/invite emails), `LDAP_CERT_CN`, and host port
overrides (`SSO_PORT`, `LDAPS_PORT`, `HTTP_PORT`, `HTTPS_PORT`,
`HTTPS_ALT_PORT`, `MGMT_PORT`). See `.env.example` for the full commented list.

## 3. Run

```bash
./setup.sh
```

What happens:

1. Validates `.env` (copies from `.env.example` if missing, then exits so you
   can edit it).
2. Builds + starts **sso-manager**, waits for `/health`.
3. Runs the **bootstrap** inside the sso-manager container — creates the LDAP
   service account, your first admin, and the proxy's OAuth client, and prints
   the client id + secret.
4. Writes **`./proxy.env`** (the proxy's `app_*` config) from `.env` + the
   bootstrap output.
5. Builds + starts **proxy**, waits for `/health`.
6. Prints your first-admin login + the public URLs.

The first run builds two Docker images (a few minutes). Subsequent runs are
fast.

## 4. Point DNS at the host

`SSO_HOST` and `PROXY_HOST` must resolve to the host running the stack. Add DNS
records, or for a local try:

```bash
echo "127.0.0.1 sso.lab.local proxy.lab.local" | sudo tee -a /etc/hosts
```

(The proxy needs port 80 reachable for Let's Encrypt; on a LAN without that it
serves a self-signed cert — browsers will warn, which is fine for home-lab use.)

## 5. Log in

Open `https://<SSO_HOST>` and log in as your bootstrap admin
(`BOOTSTRAP_ADMIN_UID` / `BOOTSTRAP_ADMIN_PASS`). From there you can add users,
groups, and OAuth clients.

The proxy mgmt UI is at `https://<PROXY_HOST>` (same admin SSO login protects
it). Add the Host records you want to protect with OIDC.

First-run fallbacks (if DNS/TLS isn't ready yet): SSO UI at
`http://127.0.0.1:3001`, proxy UI at `http://127.0.0.1:3000`.

## Re-running

`./setup.sh` is **idempotent** — safe to re-run after editing `.env`, after a
`docker compose down`, or after restoring from backup. It converges the stack to
your `.env` values (LDAP service account + admin passwords are reset to `.env`;
the OAuth client is left alone if `proxy.env` exists).

## Direct LDAP for legacy apps

Legacy apps bind LDAP directly over LDAPS:

```bash
ldapsearch -x -H ldaps://<host>:636 \
  -D "cn=ldapclient,ou=people,dc=lab,dc=local" -W \
  -b "ou=people,dc=lab,dc=local" '(objectClass=posixAccount)' cn mail
```

Use the `cn=ldapclient` service account (read-only, the bootstrap created it)
or the admin DN. Use LDAPS (636), not plain LDAP.

## Backups

```bash
docker compose exec sso-manager slapcat -f /etc/openldap/slapd.conf \
  -b "$LDAP_BASE_DN" > backup-$(date +%F).ldif
```

Keep `.env` + `proxy.env` alongside it. Restore is `ldapadd`/`ldapmodify` into a
fresh directory, then re-run `./setup.sh`.

## Next steps

- Add users / groups in the SSO UI.
- Add Host records in the proxy UI to protect your apps with OIDC.
- See [Architecture](architecture.html) for how it all fits together, and
  [Standalone](standalone.html) to run either project on its own.

[← Back to Home](index.html)