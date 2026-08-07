---
title: Canonical demo fixtures
---

# Canonical demo fixtures

The exact users, groups, and hosts that should exist on a stack used for
screenshots or demos, so every future pass seeds the *same* data and a
screenshot diff only shows what actually changed in the UI — not incidental
differences in who/what happened to exist that day.

Persona: a single admin/power-user running theta42 across a **big homelab and
a small business** — mix of self-hosted infra (Proxmox, Pi-hole, Plex) and
office-y apps (invoicing, helpdesk, wiki) with real department structure.

Domain: `laptop-dev.vm42.us` (real public DNS pointing at this machine — see
"Domain" below). Update this doc if the domain ever changes again.

## Users

| uid | Name | Department | Password | Notes |
|---|---|---|---|---|
| `schen` | Sarah Chen | Engineering | `DemoPass123!` | DevOps lead |
| `dkim` | David Kim | Engineering | `DemoPass123!` | Backend developer |
| `ppatel` | Priya Patel | Engineering | `DemoPass123!` | Frontend developer |
| `mjohnson` | Marcus Johnson | Finance | `DemoPass123!` | Finance manager |
| `lnguyen` | Linda Nguyen | Finance | `DemoPass123!` | Bookkeeper |
| `erodriguez` | Emily Rodriguez | Support | `DemoPass123!` | Support lead |
| `tbaker` | Tom Baker | Support | `DemoPass123!` | Support tech |
| `jwilson` | James Wilson | Management | `DemoPass123!` | Owner |
| `svc-monitoring` | — | service account | `ServiceAcct!2024` | Grafana/Prometheus scraping |
| `svc-backup` | — | service account | `ServiceAcct!2024` | Backup automation |

uidNumbers 5000–5009 in that order. Mail is `<first>.<last>@laptop-dev.vm42.us`
(service accounts use their uid, e.g. `monitoring@laptop-dev.vm42.us`).

## Groups

`groupOfNames`, owned by `cn=admin,...`, member of the department's users:

- `engineering` — schen, dkim, ppatel
- `finance` — mjohnson, lnguyen
- `support` — erodriguez, tbaker
- `management` — jwilson
- `app_sso_service_account` (built-in) — svc-monitoring, svc-backup

## Seeding users + groups

```sh
cd theta-env
docker cp bootstrap/seed-demo-users.sh sso-manager:/tmp/seed-demo-users.sh
docker compose exec -T sso-manager bash /tmp/seed-demo-users.sh
```

Idempotent — re-running skips anything that already exists. If you add a
fixture below, add it to `bootstrap/seed-demo-users.sh` too and keep the two
in sync.

## Proxy hosts

All under `*.laptop-dev.vm42.us`. `setup.sh` itself creates the first two
(sso, proxy) — everything else below is added by hand through Hosts → Add
host (Proxy UI, currently no seed script — see note at the bottom).

| Host | Target | Auth | Notes |
|---|---|---|---|
| `sso` | `sso-manager:3001` | — | created by `setup.sh` |
| `proxy` | `127.0.0.1:3000` | — | created by `setup.sh` |
| `jump` | `jump-host:3002` | — | created by `setup.sh` |
| `proxmox` | `10.0.10.5:8006` (HTTPS) | Basic — realm "Proxmox VE", users `dkim`, `schen` | |
| `pbs` | `10.0.10.6:8007` (HTTPS) | Basic — realm "Proxmox Backup Server", user `dkim` | |
| `grafana` | `10.0.10.12:3000` + LB target `10.0.10.13:3000` | SSO — group `engineering` | load-balancing example |
| `nextcloud` | `10.0.10.20:80` | SSO — any authenticated user | empty allow-lists |
| `ha` | `10.0.10.30:8123` | Basic — realm "Home Assistant", user `jwilson` | |
| `jenkins` | `10.0.10.40:8080` | SSO — group `engineering` | |
| `gitea` | `10.0.10.41:3000` | Off (public) | has its own login |
| `plex` | `10.0.10.50:32400` | Off (public) | has its own login |
| `nas` | `10.0.10.60:5001` (HTTPS) | Basic — realm "Synology NAS", user `jwilson` | |
| `pihole` | `10.0.10.61:80` | Basic — realm "Pi-hole Admin", user `dkim` | |
| `wiki` | `10.0.10.70:3000` | SSO — any authenticated user | |
| `invoices` | `10.0.10.80:8000` | SSO — group `finance` | small-business flavor |
| `helpdesk` | `10.0.10.81:3000` | SSO — group `support` | small-business flavor |

Basic-auth passwords used: `dkim:HomeLab!2024`, `schen:Engineering!24`,
`jwilson:HomeOwner!24`.

## Domain

`CFG_DOMAIN=laptop-dev.vm42.us` in `setup.env`, real public DNS (CNAME
through `718it.biz`) that resolves back to this machine. `CFG_LDAPS_HOST`
is pinned to the LAN IP of the interface holding the default route
(`ip route get 1.1.1.1`), not just any active interface — this machine had
two (wifi + USB ethernet) and only one was actually externally reachable
through the existing port-forward/prod-proxy setup.

A production reverse proxy in front of this host handles TLS/ACME for
`*.718it.biz`-family domains (to avoid hitting Let's Encrypt's rate limits
re-provisioning a cert every time this dev stack rebuilds) — if a fresh
rebuild's Host records don't resolve correctly from the public domain right
after `setup.sh`, that's the layer to check, not this stack's own nginx/lua
routing. `curl -sk -D - https://sso.laptop-dev.vm42.us/` from the host
machine is the fastest way to confirm whether the issue is server-side.

## Known-good login shortcuts

Skip SSO's self-signed-cert dance entirely for admin/screenshot work — every
app ships a local anti-lockout admin account for exactly this:

```sh
# SSO Manager admin (bootstrap account, uid "admin")
node -e "console.log(require('./config/sso-secrets.js').bootstrap.adminPass)"

# Proxy — username proxyadmin2
node -e "console.log(require('./config/proxy-secrets.js').auth.localAdminPass)"

# Jump-host — username jumpadmin
node -e "console.log(require('./config/jump-secrets.js').auth.localAdminPass)"
```

Ports (from `setup.env` — check it, these are operator-configurable):
SSO `3001`, Proxy management UI `3010` (`MGMT_PORT`), Jump-host `3002`.

A freshly-bootstrapped `admin` account hits the onboarding flow (accept ToS,
enter a DOB) before the rest of the UI is usable — expect that on a stack
that was just rebuilt from scratch.

## Jump-host access (SSO Directory resource)

Jump-host's dashboard ("Hosts you can reach") is **not** driven by Proxy's
Host records — it resolves access via the SSO Manager's own Directory
(`kind: host` resources), filtered by the logged-in user's LDAP group
membership. This is a completely separate system from Proxy's HTTP-routing
hosts above; a Proxy host existing does not make it SSH-reachable through
jump-host.

For a `dkim`-can-reach-something screenshot, one Directory host resource was
added:

- **Directory → Add Resource**: name `proxmox-node`, kind `Host`, IP
  `10.0.10.5`, parent resource `local (site_local)`.
- **Associated LDAP Groups → `site_local_host_proxmox-node_access` →
  Members → Add member → `dkim`** (added the individual user directly, not
  the `engineering` group — the resource's own auto-generated `_access`
  group's member picker only offers individual users).

To reproduce: repeat those two steps for `proxmox-node` if it's missing, or
add more Directory host resources the same way for a richer "Hosts you can
reach" list.

**To screenshot as a real fixture user** (not the `jumpadmin` local
anti-lockout admin, whose "My hosts" list is always non-empty by virtue of
infra ownership, not a real access grant): log out, click "Log in with
Jump" on the login page, and sign in as `dkim` / `DemoPass123!` through the
real SSO flow. This exercises the actual OIDC redirect through
`sso.laptop-dev.vm42.us` — by this point in the session it worked cleanly in
the browser; if it doesn't (stale cookies/redirect loop from an earlier bad
state), see `docs/screenshots.md` §2 for the fallback.

## What's not yet automated

Proxy hosts are still added by hand (no `seed-demo-hosts.sh` equivalent) —
the Proxy UI has no simple LDIF-style bulk-import path the way LDAP does, and
scripting it means either driving the browser or reverse-engineering the
session-cookie login flow for curl. If this list changes often enough to be
annoying, that's the next thing worth building — a small node script run via
`docker compose exec proxy node ...` calling the `Host` model directly,
mirroring how `setup.sh`'s own step 7 registers the sso/proxy hosts.

## Screenshot workflow

See `docs/screenshots.md` for the full screenshot-capture workflow
(save-to-disk, where each doc image lives, the app.modal.js browser-cache
gotcha). Once fixtures match this doc, only re-screenshot pages whose UI
actually changed since the last pass — the data itself shouldn't be the
reason a screenshot looks different.
