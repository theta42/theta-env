---
title: Updating gitpages screenshots
---

# Updating gitpages screenshots

How to refresh the docs/images/*.png screenshots across sso-manager-node,
proxy, jump-host, and theta-env's own docs. This comes up periodically as the
UI changes — this doc + `docs/fixtures.md` + `bootstrap/seed-demo-users.sh`
exist so it doesn't have to be re-figured-out from scratch each time. Once
fixtures match `docs/fixtures.md`, you only need to re-screenshot pages whose
UI actually changed since the last pass.

## 1. Seed realistic demo data

Screenshots should show a believable homelab/small-business setup, not empty
tables or `test`/`vaulttest` accounts, and the **same** cast every time — see
`docs/fixtures.md` for the canonical list (exact users, groups, hosts,
passwords) and keep it in sync with what's actually seeded. Seed users +
groups with:

```sh
docker cp bootstrap/seed-demo-users.sh sso-manager:/tmp/seed-demo-users.sh
docker compose exec -T sso-manager bash /tmp/seed-demo-users.sh
```

Idempotent — safe to re-run, existing entries are skipped. Proxy hosts have
no equivalent script yet — add them by hand through the Proxy UI (Hosts →
Add host), following `docs/fixtures.md`'s host table exactly (same hostnames,
targets, auth config every time).

## 2. Logging in without fighting SSO/TLS

The SSO's own domain goes through real DNS + a production reverse proxy in
front of this dev stack (see `docs/fixtures.md` → Domain) — logging in via
"Log in with SSO" from Proxy/Jump-host round-trips through that whole path
and can hit stale-cookie/redirect-loop artifacts in an automation browser
profile that a real browser wouldn't. Don't fight this — every app ships a
local anti-lockout admin for exactly this situation. Read the password
straight out of the mounted secrets:

```sh
# SSO Manager admin (bootstrap account, uid "admin")
node -e "console.log(require('./config/sso-secrets.js').bootstrap.adminPass)"

# Proxy — username proxyadmin2
node -e "console.log(require('./config/proxy-secrets.js').auth.localAdminPass)"

# Jump-host — username jumpadmin
node -e "console.log(require('./config/jump-secrets.js').auth.localAdminPass)"
```

Log in at `http://localhost:<port>/login` for each app — plain HTTP on the
mapped port, no cert/cookie issues at all. Ports come from `setup.env`
(operator-configurable) — check it rather than assuming defaults; e.g. this
deployment maps the Proxy UI to `3010` (`MGMT_PORT`), not the usual `3000`.

**Don't touch the login form if it autofills a real saved username/password**
(Chrome profile password manager) — clear the fields and type the local admin
credentials above instead. Never submit a real saved credential on the
user's behalf.

A freshly-bootstrapped `admin` account hits the onboarding flow (accept ToS,
enter a DOB) before the rest of the UI is usable — expect that right after a
from-scratch rebuild.

## 3. Known gotcha: stale `app.modal.js` in the browser cache

If "Add host" (or any `app.modal`-based modal) opens with tabs/fields but no
Save/Cancel footer, check the console for
`TypeError: app.modal.on is not a function`. That means the browser has an
HTTP-cached copy of `@simpleworkjs/frontend/lib/app.modal.js` from before a
method (`on`, `showTab`, etc.) was added — `curl`-ing the same URL returns the
current file, so it's a caching artifact, not a real app bug. Fix it in-page
without a full hard-reload cycle:

```js
// via the browser automation JS tool, in the page context
const res = await fetch('/static-modules/@simpleworkjs/frontend/lib/app.modal.js', {cache: 'reload'});
await res.text(); // {cache:'reload'} both bypasses AND refreshes the cache entry
```

Then reload the page normally — the fresh file sticks for the rest of the
session.

## 4. Capture screenshots

Use `save_to_disk: true` on the browser screenshot action so files land on
disk instead of just being viewed inline. One screenshot per doc image:

| File | Page |
|---|---|
| `sso-manager-node/docs/images/dashboard.png` | SSO Catalog (`/`) |
| `sso-manager-node/docs/images/users.png` | SSO Users → People (`/users`) |
| `sso-manager-node/docs/images/directory.png` | SSO Directory (`/directory`) |
| `sso-manager-node/docs/images/groups.png` | A user's profile → "My Groups" tab |
| `sso-manager-node/docs/images/oauth-clients.png` | Directory → an `oauth` resource → Edit → Details tab |
| `proxy/docs/images/hosts.png` | Proxy Hosts list (`/hosts`) |
| `proxy/docs/images/host-auth-basic.png` | Edit a basic-auth host → Authentication tab |
| `proxy/docs/images/host-auth-sso.png` | Edit an SSO-auth host → Authentication tab |
| `proxy/docs/images/load-balancing.png` | Edit a host with "Additional Targets" filled in → General tab |
| `jump-host/docs/images/login.png` | Jump-host login page |
| `jump-host/docs/images/dashboard.png` | Jump-host dashboard, logged in as a real fixture user (e.g. `dkim` via SSO) with an actual access grant — not the `jumpadmin` local admin, whose host list isn't representative. See `docs/fixtures.md` → Jump-host access. |
| `jump-host/docs/images/sessions.png` | Jump-host active sessions |
| `jump-host/docs/images/audit.png` | Jump-host audit log |
| `theta-env/docs/images/sso-dashboard.png` | same as SSO Catalog above |
| `theta-env/docs/images/proxy-hosts.png` | same as Proxy Hosts above |
| `theta-env/docs/images/jump-dashboard.png` | same as Jump-host dashboard above |

## 5. Where to save them

Only update the **top-level active clones** —
`/home/william/dev/theta42/{sso-manager-node,proxy,jump-host,theta-env}` (all
on `master`). The copies nested under `theta-env/sso-manager-node`,
`theta-env/proxy`, `theta-env/jump-host` are git submodules pinned to a
release tag (`HEAD detached at vX.Y.Z`) — those update automatically the next
time theta-env's release/tag-bump workflow rolls the submodule pointer
forward, not by hand-editing the pinned checkout.

```sh
convert screenshot.jpg /home/william/dev/theta42/<repo>/docs/images/<name>.png
```

(`convert` from ImageMagick — the browser tool saves JPEGs, but the repos
track PNGs.)

Commit each repo separately, same as any other change to that component.
