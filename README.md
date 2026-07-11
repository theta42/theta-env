# theta-env

The whole theta42 identity + access stack in one repo, brought up with a single
command — for home labs and small businesses.

It wires together two projects that already work on their own:

- **[SSO Manager](https://github.com/theta42/sso-manager-node)** — an OIDC
  provider with a built-in LDAP directory (OpenLDAP) and a web UI for managing
  users, groups, and OAuth clients.
- **[theta42/proxy](https://github.com/theta42/proxy)** — an OIDC-protected
  reverse proxy (OpenResty) that puts any of your apps behind SSO login and can
  look users up directly in LDAP.

Each project still runs **standalone** (`docker compose up` in its own folder);
this repo just composes them and automates the first-run glue so they find each
other.

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

The proxy fronts the SSO Manager UI under TLS and protects it with OIDC login.
It is **both** an OIDC client of the SSO (for login) **and** a direct LDAP
client (for user lookups). Legacy apps can still bind to LDAPS on the SSO
directly.

---

## Before you begin

You'll need three things set up ahead of time — a domain, DNS records, and port
forwarding. The setup script can't do these for you; they're outside the host.

### 1. A domain you control

You need a real DNS domain (e.g. `lab.example.com`) because the proxy issues
real TLS certificates for it via Let's Encrypt. A `.local` or made-up name only
gets you a self-signed cert (browsers will warn — fine for testing, painful for
daily use).

### 2. At least two hostnames, pointing at your public IP

You need a DNS **`A` record** for each hostname you want the stack to serve,
all pointing at the **public IP** of the host running this stack (or your
router, if the host is behind it). At a minimum:

| Hostname (example) | What it serves |
|--------------------|----------------|
| `sso.lab.example.com`  | The SSO Manager UI (login, user/group/OAuth-client admin). |
| `proxy.lab.example.com`| The proxy's own management UI (add the apps you want to protect). |

Two is the **minimum**. You'll almost certainly want **more**: every app you put
behind the proxy needs *its own* hostname too (e.g. `wiki.lab.example.com`,
`photos.lab.example.com`). Add those DNS records as you add apps — create them
now if you already know what you'll front.

> **Quick local test, no DNS?** You can skip real DNS by adding the hostnames
> to `/etc/hosts` on the machine you browse from, pointing at the stack host.
> The proxy will then fall back to a self-signed cert. Fine for kicking the
> tires, not for real use.

### 3. Port forwarding: 80 and 443 to the host

On your router / firewall, forward these from your public IP to the host
running the stack:

| Port | Why |
|------|-----|
| **80** (HTTP)  | Required for Let's Encrypt to verify domain ownership (ACME HTTP-01 challenge). Without it, you get the self-signed fallback. |
| **443** (HTTPS) | The real traffic — all the UIs and proxied apps. |

Both must reach the host. Port **80 must be reachable from the internet** even
though you'll only *use* 443 — that's just how Let's Encrypt validates. (If you
really can't open 80, the stack still runs on the self-signed cert; you'll just
see browser warnings.)

Optional extra ports (only if you need them):
- **4443** — alternate HTTPS listener (e.g. if 443 is taken by something else).
- **636** (LDAPS) — only if a legacy app on another machine binds to LDAP
  directly over the network. The proxy itself reaches LDAP over the internal
  Docker network, so you do **not** need to expose 636 for the stack to work.

### 4. Docker + Docker Compose

Any recent Docker with Compose — the v2 plugin (`docker compose`) or the v1
standalone (`docker-compose`) both work.

---

## Quickstart

```bash
git clone --recursive https://github.com/theta42/theta-env.git
cd theta-env
cp .env.example .env        # then edit .env (see below)
./setup.sh
```

`./setup.sh` is idempotent — re-run it any time to converge the stack to your
`.env`. It:

1. Builds + starts the SSO Manager container, waits for it to be healthy.
2. Runs the bootstrap (`bootstrap/bootstrap.js`) **inside** the SSO container,
   which:
   - creates the LDAP service account the proxy binds as
     (`cn=ldapclient,ou=people,<base>`),
   - creates your first admin user and adds them to the `app_sso_admin` +
     `app_sso_oauth_admin` groups,
   - registers the proxy as an OIDC client in the SSO, and
   - prints the client id + secret.
3. Writes `./proxy.env` (the proxy's config — OIDC endpoints, LDAP bind,
   client creds) from your `.env` + the bootstrap output.
4. Builds + starts the proxy container, waits for it to be healthy.
5. Prints your first admin login + the public URLs.

### `.env` — the values you must set

Copy `.env.example` to `.env` and at minimum set:

| Key | What it is |
|-----|------------|
| `LDAP_BASE_DN` | Your directory base, e.g. `dc=lab,dc=local`. |
| `LDAP_ADMIN_PASS` | The LDAP root password. **Save it** — needed for raw LDAP admin. |
| `JWT_SECRET` | Signs the SSO's access/refresh tokens. Leave blank to auto-generate + persist. **Save it.** |
| `SSO_HOST` | Public hostname the proxy serves the SSO UI at, e.g. `sso.lab.local`. |
| `PROXY_HOST` | Public hostname the proxy serves its own mgmt UI at, e.g. `proxy.lab.local`. |
| `BOOTSTRAP_ADMIN_UID` / `BOOTSTRAP_ADMIN_PASS` | Your first admin login. Re-running `setup.sh` resets this password. |

> **Values with spaces:** quote them, e.g. `ORG_NAME="My Org"` or
> `SMTP_FROM="Theta SSO <noreply@example.com>"`. Quotes are optional but
> recommended anywhere a value contains spaces — `setup.sh` and `docker
> compose` both strip a single pair of matching outer quotes.

Optional: `BOOTSTRAP_ADMIN_EMAIL`, `LDAP_SERVICE_PASS` (auto-generated if blank),
`SMTP_*` (for SSO password-reset/invite emails), and host port overrides
(`SSO_PORT`, `LDAPS_PORT`, `HTTP_PORT`, `HTTPS_PORT`, `HTTPS_ALT_PORT`,
`MGMT_PORT`). See `.env.example` for the full list with comments.

---

## After setup

- **SSO Manager UI**: `https://<SSO_HOST>` — log in as your bootstrap admin to
  add users, groups, and OAuth clients. (First-run fallback:
  `http://127.0.0.1:3001`.)
- **Proxy mgmt UI**: `https://<PROXY_HOST>` — add the Host records you want to
  protect with OIDC. (First-run fallback: `http://127.0.0.1:3000`.)
- **Direct LDAP for legacy apps**: bind to `ldaps://<host>:636` as
  `cn=admin,<base>` (admin) or `cn=ldapclient,ou=people,<base>` (read-only
  service account the bootstrap created). Use LDAPS, not plain LDAP.

---

## Backups

The directory lives in the `ldap-data` Docker volume. Back it up with `slapcat`
(the portable LDIF export — survives OpenLDAP version upgrades):

```bash
docker compose exec sso-manager slapcat -f /etc/openldap/slapd.conf -b "$LDAP_BASE_DN" > backup.ldif
```

Restore is `ldapadd`/`ldapmodify` from that LDIF into a fresh directory. Also
keep your `.env` (it holds `LDAP_ADMIN_PASS` + `JWT_SECRET`) and `proxy.env`.

---

## Running each project standalone

The two submodules work on their own — this repo just composes them:

- **SSO Manager alone**:
  ```bash
  cd sso-manager-node
  cp secrets.js.example nodejs/conf/secrets.js   # edit it
  docker compose up -d --build
  ```
  See its [DEPLOYMENT.md](sso-manager-node/DEPLOYMENT.md).

- **Proxy alone** (pointing at any external SSO + LDAP via `app_*` env or a
  mounted `secrets.js`):
  ```bash
  cd proxy
  docker compose up -d --build
  ```
  See its [DEPLOYMENT.md](proxy/DEPLOYMENT.md).

No cross-repo file edits are needed at runtime — the unified stack is pure
composition (one compose file + one bootstrap script).

---

## How the first-run wiring works

`bootstrap/bootstrap.js` runs inside the SSO Manager container (bind-mounted
read-only from this repo) and is deliberately self-contained: it uses only Node
built-ins (`child_process`, `crypto`) + global `fetch`. LDAP operations use the
`openldap-clients` binaries (`ldapadd`/`ldapsearch`/`ldapmodify`) with explicit
admin creds from `.env`; the OAuth client is created via the SSO's own HTTP API
(logging in as the bootstrapped admin, which also validates that admin's
password end-to-end). It does **not** `require` the SSO's internal models, so it
never has to fight the app's config layer.

It's idempotent: re-running converges to your `.env` values. The LDAP service
account + admin passwords are reset to `.env` on each run; the OAuth client is
created if missing, left alone if `proxy.env` is present, or rotated if
`proxy.env` was lost (so a wiped-and-restored proxy gets a secret it can read).

Passwords are stored as `{SSHA512}` (the SSO's `hashPasswordSSHA512`, replicated
exactly in the bootstrap) so the SSO can verify them on bind.

---

## Security notes

1. **Only expose 443 (and optionally 4443) to the internet.** The SSO's web port
   (`3001`) is bound to localhost — the proxy fronts it. LDAPS (`636`) is the
   only LDAP listener that should cross the network.
2. **Persist + protect `.env` and `proxy.env`.** They hold `LDAP_ADMIN_PASS`,
   `JWT_SECRET`, the LDAP service password, and the OAuth client secret.
   `setup.sh` writes `proxy.env` mode `0600`; both are in `.gitignore`.
3. **LDAPS uses the SSO's self-signed cert by default.** The proxy binds with
   `app_ldap__tlsOptions__rejectUnauthorized=false`. For strict trust, mount
   the SSO's cert (`ldap-certs` volume) into the proxy and set
   `app_ldap__tlsOptions__ca=<path>` in `proxy.env`.
4. **Re-running `setup.sh` resets the bootstrap admin + service passwords to
   `.env`.** If you change a user's password in the SSO UI later, re-running
   `setup.sh` will reset the bootstrap admin's password back to
   `BOOTSTRAP_ADMIN_PASS`.
5. Both containers run their app process as root (matching the bare-metal
   systemd units) for simplicity at this scale. Harden to a non-root user for
   a stricter deployment.

---

## Repo layout

```
theta-env/
├── .env.example          # copy to .env, edit
├── docker-compose.yml    # sso-manager + proxy on one bridge net
├── setup.sh              # one-command idempotent bring-up
├── bootstrap/
│   └── bootstrap.js      # runs in the sso-manager container
├── sso-manager-node/     # git submodule
└── proxy/                # git submodule
```

The two submodules pin a known-good version of each project. Update them with
`git submodule update --remote` (then re-run `setup.sh` to rebuild).