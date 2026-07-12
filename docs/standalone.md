---
layout: default
title: Standalone
---

# Running each project standalone

[← Back to Home](index.html)

theta-env composes the two projects but doesn't fork them — both work on their
own. The submodules in this repo are normal clones; you can also clone them
directly from GitHub.

## SSO Manager alone

The all-in-one image (`Dockerfile.openldap`) bundles the app + OpenLDAP + Redis:

```bash
git clone https://github.com/theta42/sso-manager-node.git
cd sso-manager-node
mkdir -p config && cp secrets.js.example config/sso-secrets.js   # edit it
docker compose up -d --build
```

The entrypoint symlinks `config/sso-secrets.js` to `nodejs/conf/secrets.js` so
`@simpleworkjs/conf` reads it. Set `ldap.bindPassword`, `oauth.jwtSecret`, and
the `stack`/`bootstrap` keys (the app ignores the ones it doesn't use). Pass
**no `app_*` env** — env beats `secrets.js`, so `app_*` would silently override
your file.

- Web UI: `http://localhost:3001`
- Health: `http://localhost:3001/health`
- OIDC discovery: `http://localhost:3001/.well-known/openid-configuration`
- LDAPS: `ldaps://<host>:636`

Requires `@simpleworkjs/conf` >= 1.1.0. Full reference:
[SSO Manager deployment docs](https://theta42.github.io/sso-manager-node/deployment.html).

### Bare metal

```bash
sudo ./install.sh -p 'your-ldap-password' -b 'dc=yourdomain,dc=com' -n 'Your Org' -o 3001
sudo systemctl enable --now sso-manager
```

Idempotent — re-run to update. See the SSO Manager
[deployment guide](https://theta42.github.io/sso-manager-node/deployment.html).

## Proxy alone

The all-in-one image (`Dockerfile`) bundles OpenResty + the Node app + Redis:

```bash
git clone https://github.com/theta42/proxy.git
cd proxy
mkdir -p config && cp secrets.js.example config/proxy-secrets.js   # edit it
docker compose up -d --build
```

The entrypoint symlinks `config/proxy-secrets.js` to `nodejs/conf/secrets.js` so
`@simpleworkjs/conf` reads it. Fill in `oidc` (your SSO's endpoints +
`clientId`/`clientSecret`/`redirectUri`), `ldap` (bind creds + search base), and
`auth` (admin groups/users). Pass **no `app_*` env** — env beats `secrets.js`,
so `app_*` would silently override your file.

- Proxy (public, auto-SSL): `https://<host>/`
- Mgmt UI / API: `http://127.0.0.1:3000/`
- Health: `http://127.0.0.1:3000/health`

Requires `@simpleworkjs/conf` >= 1.1.0. Full reference:
[proxy deployment docs](https://theta42.github.io/proxy/docker.html).

### Bare metal

```bash
wget -O - https://raw.githubusercontent.com/theta42/proxy/master/ops/install.sh | sudo bash
```

See the proxy
[Docker guide](https://theta42.github.io/proxy/docker.html) /
[installation guide](https://theta42.github.io/proxy/installation.html).

## Mixing and matching

theta-env isn't required to use the two together — the four wiring steps are
documented in both projects' deployment guides:

1. One Docker network (or reachable hostnames) so the proxy can reach the SSO
   internally for token/userinfo + LDAPS.
2. Set the SSO's `oauth.issuer` (in its `secrets.js`) to the browser-facing HTTPS
   URL the proxy serves the SSO at.
3. Register the proxy as an OIDC client in the SSO, with `redirectUri` matching
   the proxy's callback; put the resulting `clientId`/`clientSecret` in the
   proxy's `secrets.js`.
4. Point the proxy's `ldap.url` at the SSO's LDAPS + create a dedicated
   `cn=ldapclient` service account; set the same password as `bindPassword`.

theta-env just automates those four steps with `./setup.sh`. If you prefer to
do them by hand (or want the two on separate hosts), follow the standalone
guides above.

[← Back to Home](index.html)