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
# Option A: configure via app_* env (preferred for Docker):
LDAP_ADMIN_PASS='choose-a-strong-password' \
JWT_SECRET="$(openssl rand -hex 32)" \
docker compose up -d --build

# Option B: configure via a file:
cp secrets.js.example nodejs/conf/secrets.js   # edit it
docker compose up -d --build
```

- Web UI: `http://localhost:3001`
- Health: `http://localhost:3001/health`
- OIDC discovery: `http://localhost:3001/.well-known/openid-configuration`
- LDAPS: `ldaps://<host>:636`

Requires `@simpleworkjs/conf` >= 1.1.0 for `app_*` env overrides. Full reference:
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
# Wire it to an external SSO + LDAP via app_* env (or nodejs/conf/secrets.js):
cat > .env <<EOF
app_oidc__issuer=https://sso.example.com
app_oidc__authorizationEndpoint=https://sso.example.com/oauth/authorize
app_oidc__endSessionEndpoint=https://sso.example.com/oauth/logout
app_oidc__tokenEndpoint=https://sso.example.com/oauth/token
app_oidc__userinfoEndpoint=https://sso.example.com/oauth/userinfo
app_oidc__clientId=...
app_oidc__clientSecret=...
app_oidc__redirectUri=https://proxy.example.com/api/auth/oidc/callback
app_ldap__url=ldaps://sso.example.com:636
app_ldap__bindDN=cn=ldapclient,ou=people,dc=example,dc=com
app_ldap__bindPassword=...
app_ldap__searchBase=ou=people,dc=example,dc=com
app_ldap__userFilter=(objectClass=posixAccount)
app_ldap__tlsOptions__rejectUnauthorized=false
EOF
docker compose up -d --build
```

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
2. Set the SSO's `OAUTH_ISSUER` / `app_oauth__issuer` to the browser-facing HTTPS
   URL the proxy serves the SSO at.
3. Register the proxy as an OIDC client in the SSO, with `redirectUri` matching
   the proxy's callback.
4. Point the proxy's `app_ldap__url` at the SSO's LDAPS + create a dedicated
   `cn=ldapclient` service account.

theta-env just automates those four steps with `./setup.sh`. If you prefer to
do them by hand (or want the two on separate hosts), follow the standalone
guides above.

[← Back to Home](index.html)