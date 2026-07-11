---
layout: default
title: Home
---

# theta-env

A single repo that runs the whole theta42 identity + access stack —
[SSO Manager](https://github.com/theta42/sso-manager-node) (OIDC provider + LDAP)
and the [theta42/proxy](https://github.com/theta42/proxy) (OIDC-protected reverse
proxy) — together, with **one command**, for home labs and small businesses.

It exists for people whose needs are met by these two projects and who want to
run them "very simply." Each project still works **standalone**; this repo just
wires them together and automates the first-run glue.

## Quick start

```bash
git clone --recursive https://github.com/theta42/theta-env.git
cd theta-env
cp .env.example .env        # edit the REQUIRED values (below)
./setup.sh
```

You need **Docker** + **Docker Compose**. `./setup.sh` is idempotent — re-run any
time to converge the stack to your `.env`.

See the [Quickstart Guide](quickstart.html) for a walkthrough of every `.env`
value and what `setup.sh` does, [Architecture](architecture.html) for how the
pieces fit together, and [Standalone](standalone.html) for running each project
on its own.

## What you get

- **SSO Manager** at `https://<SSO_HOST>` — log in as your first admin to manage
  users, groups, and OAuth clients. Fronted by the proxy under TLS.
- **Proxy** at `https://<PROXY_HOST>` — add the Host records you want to protect
  with OIDC login.
- **LDAPS** at `ldaps://<host>:636` — legacy apps can bind directly (admin or
  the read-only `cn=ldapclient` service account the bootstrap creates).

## The `.env` values you must set

| Key | What it is |
|-----|------------|
| `LDAP_BASE_DN` | Directory base, e.g. `dc=lab,dc=local`. |
| `LDAP_ADMIN_PASS` | LDAP root password. **Save it.** |
| `JWT_SECRET` | Signs the SSO's tokens. Leave blank to auto-generate + persist. **Save it.** |
| `SSO_HOST` | Public hostname the proxy serves the SSO UI at. |
| `PROXY_HOST` | Public hostname the proxy serves its own mgmt UI at. |
| `BOOTSTRAP_ADMIN_UID` / `BOOTSTRAP_ADMIN_PASS` | Your first admin login. |

See `.env.example` for the full list (SMTP, port overrides, LDAP cert CN, …).

## Architecture

```
            ┌──────────────────────────────────────────────┐
            │  your browser / apps                          │
            └───────────────┬──────────────────────────────┘
                            │ https
                  ┌─────────▼─────────┐
                  │  proxy            │  OpenResty :80/:443/:4443
                  │  (OIDC + LDAP)    │  mgmt app :3000 (localhost)
                  └─────────┬─────────┘  bundled redis
              ┌─────────────┼──────────────────────┐
              │ ldaps:636   │ http:3001 (internal)│  OIDC token/userinfo
              ▼             ▼                      │
      ┌──────────────────────────┐                │
      │  sso-manager             │◄────────────────┘
      │  OIDC provider + OpenLDAP │  bundled redis
      │  web UI :3001 (localhost) │
      │  ldaps :636 (LAN clients) │
      └───────────────────────────┘
```

The proxy is **both** an OIDC client of the SSO (for login) **and** a direct LDAP
client (for user lookups). See [Architecture](architecture.html) for the full
diagram + the first-run bootstrap flow.

## Documentation

- [Quickstart Guide](quickstart.html) — full walkthrough of `.env` + `setup.sh`.
- [Architecture](architecture.html) — the 3-repo + submodule + 2-container
  design, and how the bootstrap wires the proxy into a fresh SSO.
- [Standalone](standalone.html) — running SSO Manager or the proxy on its own.

## Community

- [GitHub Repository](https://github.com/theta42/theta-env)
- [Issue Tracker](https://github.com/theta42/theta-env/issues)

## License

MIT License — see the repository for details.