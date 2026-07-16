---
layout: default
title: Home
---

# theta-env

The whole theta42 identity + access stack in one repo, brought up with a
single command — for home labs and small businesses.

It wires together two projects that already work on their own —
[SSO Manager](https://theta42.github.io/sso-manager-node/) (OIDC provider +
LDAP directory) and [Proxy](https://theta42.github.io/proxy/) (an
OIDC-protected reverse proxy that can also look users up directly in LDAP) —
and automates the fiddly part: registering the proxy as an OIDC client of the
SSO and pointing it at the right LDAP directory, with hostnames and secrets
generated from one `setup.env`.

## Screenshots

The SSO Manager and the proxy it fronts, both stood up by one `./setup.sh` run:

<a href="images/sso-dashboard.png" target="_blank"><img src="images/sso-dashboard.png" alt="SSO Manager dashboard" width="49%"></a>
<a href="images/proxy-hosts.png" target="_blank"><img src="images/proxy-hosts.png" alt="Proxy host list" width="49%"></a>

*(click either screenshot to view full size)*

## Why this over running them separately

Each project works standalone, but they only become useful together once the
proxy is registered as an OIDC client of the SSO *and* pointed at the SSO's
LDAP directory — and the domain has to match across half a dozen config
fields, or logins silently fail. Doing that by hand is fiddly. `setup.sh`
asks for your domain once, generates both apps' config with it filled in
everywhere, registers the proxy as an OIDC client automatically, and
snapshots state before every rebuild.

## What you get

- **SSO Manager**, fronted by the proxy under TLS — manage users, groups,
  and OAuth clients.
- **Proxy** — add the hosts you want to protect with OIDC login.
- **LDAPS** for legacy apps that bind directly.
- **Self-service API tokens** in both apps' UIs, for scripting/CI without a
  browser session.

## Get it

```bash
git clone --recursive https://github.com/theta42/theta-env.git
cd theta-env
cp setup.env.example setup.env     # then edit setup.env: set CFG_DOMAIN to your domain
./setup.sh
```

You need **Docker** + **Docker Compose**. `./setup.sh` is idempotent — re-run
any time to converge the stack to `./config/`. For the full config reference,
architecture, and running each project standalone, see the
**[GitHub repository](https://github.com/theta42/theta-env)**.

## More docs

- **[Quickstart](quickstart.html)** — prerequisites and a step-by-step first run.
- **[Architecture](architecture.html)** — how the pieces fit together.
- **[Running each project standalone](standalone.html)** — using the SSO
  Manager or the proxy on their own, without theta-env.

## Related projects

- **[SSO Manager](https://theta42.github.io/sso-manager-node/)** — the OIDC
  provider + LDAP directory this stack runs.
- **[Proxy](https://theta42.github.io/proxy/)** — the reverse proxy this
  stack runs in front of it.
