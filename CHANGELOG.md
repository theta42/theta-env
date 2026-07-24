# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
correspond to git tags (`vX.Y.Z`). Entries here cover theta-env's own
orchestration code; see each submodule's own `CHANGELOG.md`
([proxy](https://github.com/theta42/proxy/blob/master/CHANGELOG.md),
[sso-manager-node](https://github.com/theta42/sso-manager-node/blob/master/CHANGELOG.md))
for what changed inside the apps it composes.

## [Unreleased]

### Added
- The bootstrap now provisions the jump host's **web-UI SSO login** when the jump host is enabled: it mints a dedicated `theta-jump` OAuth client and writes a full `oidc` block (endpoints, client id/secret, callback) plus a generated local anti-lockout admin password into `./config/jump-secrets.js`. Matches how the proxy's OIDC client is provisioned. An existing pre-OIDC `jump-secrets.js` (API token but no OIDC client) is regenerated so upgraders get SSO login. Requires jump-host ≥ v1.1.0.

## [1.3.6] - 2026-07-23

### Bumped
- sso-manager-node -> [v1.3.2](https://github.com/theta42/sso-manager-node/releases/tag/v1.3.2)

sso-manager-node 1.3.2:

### Fixed
- **OAuth client management API returned `client_id: undefined` on every GET**, which broke this stack's bootstrap: it lists the OAuth clients and rotates by the returned `client_id`, so it called `/api/oauth/client/undefined/rotate` and got a 500 — aborting `setup.sh` with `bootstrap failed` whenever `proxy-secrets.js` had no usable secret (e.g. a fresh/rotated deployment). The ORM's `toJSON()` was stripping the mapped `client_id`/`scopes`/… fields; `OAuthClient.get()` now emits them explicitly (and omits `client_secret_hash`). Unknown client ids now 404 instead of 500.

## [1.3.5] - 2026-07-23

### Added
- **Optional SSH jump host** (theta42/jump-host) as a third, opt-in submodule. Enable with `CFG_JUMP_HOST_ENABLED=true` in `setup.env`: setup.sh clones/tag-tracks the submodule and builds it behind the `jump-host` compose profile, the bootstrap mints a directory API token and writes `./config/jump-secrets.js` (LDAP admin bind so it can inject users' `sshPublicKey`), the jump host is registered as a proxy Host (its web UI) and seeded as a directory service. Users then `ssh uid_-_host@jump.<domain>` (WinSCP-friendly) or `ssh uid@jump.<domain>` for a TUI host picker; the web UI on :3002 shows audit + metrics. Off by default — existing installs are unaffected.

## [1.3.4] - 2026-07-23

### Bumped
- sso-manager-node -> [v1.3.1](https://github.com/theta42/sso-manager-node/releases/tag/v1.3.1)

sso-manager-node 1.3.1:

### Added
- The Directory documentation (`docs/directory.md`) is now surfaced: registered in-app at `/docs/directory` ("Directory & Inventory"), help-linked from the Directory page header, and linked from the docs-site index. Extended with the shared slug conventions (`site_<name>`, `host_<hostname>` — as used by ldap-client and the theta-env seed), the automatic-registration story (theta-env stack seeding, ldap-client Linux host enrollment), and the API surface (admin at `/api/directory-admin`, read-only graph at `/api/discovery`).

### Changed
- Direct LDAP binds are described as first-class, not "legacy", across README, DEPLOYMENT.md, docs, and the Dockerfile: Linux hosts are a primary consumer of the directory (PAM/SSSD login, LDAP-backed `sudo` via `sudoRole`, SSH public keys via openssh-lpk) — exactly what the custom schemas exist for.

### theta-env own changes

### Added
- `CFG_SITE_NAME` in `setup.env` (right below `CFG_DOMAIN`, default `local`): names the SSO directory site the stack registers itself under — slug `site_<name>`, matching the `parentSlug` convention ldap-client-joined Linux hosts use, so they land under the same site.
- The directory seed now collects real host facts on the machine (hostname, IP, MAC of the default-route interface, OS pretty-name, kernel — same collection as `ldap-client/index.sh`) and registers the stack host as `host_<hostname>` with that metadata, plus fills in each service's internal port and git repo (`sso-manager` 3001, `proxy` 3000, `openldap` 389/636, `openresty` 443). Existing resources from the earlier seed layout (`stack-host`, domain-slug site) are adopted in place — seed metadata only fills fields the operator hasn't set, never overwrites.
- The bootstrap now seeds the SSO directory with the stack's own resources: a site (from the configured domain), a "Stack host", and the SSO Manager + Proxy services (with their public URLs in metadata), linking the proxy's auto-registered OAuth client under its service. Also seeds the two non-obvious services the stack runs: the OpenLDAP directory (advertising the `ldaps://` endpoint Linux hosts and LDAP-native apps bind to, honoring `ldap.ldapsHost`) and the OpenResty edge (the 80/443 data plane every hostname flows through, with a wildcard `https://*.<domain>` address). The Directory page is populated out of the box instead of starting empty. Idempotent — resources whose slug already exists are operator-owned and never touched, and a seed failure only warns (never fails a bring-up, e.g. against an older sso-manager image without `/api/directory`).

## [1.3.3] - 2026-07-23

### Bumped
- sso-manager-node -> [v1.3.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.3.0) (from v1.1.18; includes the intermediate v1.2.1 release)

sso-manager-node 1.3.0:

### Added
- **OAuth client management API** at `/api/oauth/client` (group `app_sso_oauth_admin`): list, create, update, delete, and rotate-secret for OAuth clients, backed by the Resource model. Accepts form-style string inputs (newline-separated `redirect_uris`/`allowed_groups`, space-separated `scopes`).
- **Dockerized test suite**: `docker-compose -f docker-compose.test.yml up --build` spins up OpenLDAP + Redis + a test-runner that seeds the test user and runs the full jest suite (174 tests) against them. `tests/globalSetup.js` honors `REDIS_URL`.

### Fixed
- Completed the model-redis → `@simpleworkjs/orm` port that shipped half-finished in 1.2.1:
  - `OtpToken.issue`/`verify` called nonexistent `find()`/`listDetail()` — every OTP login 500'd.
  - Impersonation create/revoke called nonexistent `ImpersonationToken.listDetail()` — both endpoints 500'd.
  - `OAuthClient` read `is_valid` from the Resource model, which has no such column — every client evaluated as disabled and **all `/oauth/authorize` requests were rejected with 400**. Client validity now lives in `metadata` (absent = valid).
  - `OAuthClient.add` didn't set the required-unique `Resource.slug`; clients now get a slug derived from the client name.
  - `GET /api/token/:name/:token` returned `{results: null}` with 200 for unknown tokens (orm `get()` returns null instead of throwing); now 404s.
- `User.login` returns a clean 401 instead of crashing when neither `uid` nor `username` is supplied.
- Depend on published `@simpleworkjs/orm` ^0.2.8 and `model-redis` ^1.6.0 instead of a local `file:` link that broke `npm ci` in docker builds.

### Changed
- Removed the Mobile Phone field from the user create/edit form.

sso-manager-node 1.2.1:

### Added
- **Actionable Metrics**: New real-time metrics tracking for failed logins, top IPs, and service usage per user.
- **LDAP Monitor**: Background service to parse OpenLDAP binds over port 389 and track metrics for legacy apps.
- **UI Updates**: Executive dashboard now displays actionable metrics cards instead of raw logs. User profiles show individual service usage stats to admins.
- **Directory Management**: Integrated site/host/service abstractions into directory UI and allowed associating OAuth apps directly to services.

## [1.3.2] - 2026-07-21

### Bumped
- proxy -> [v1.2.2](https://github.com/theta42/proxy/releases/tag/v1.2.2)

proxy:

### Fixed
- Multi-target load balancing (added in 1.2.0) crashed every request to a load-balanced host: `ops/nginx_conf/targetinfo.lua` required a nonexistent `resty.balancer.round_robin` module. The `lua-resty-balancer` rock actually installed provides `resty.roundrobin` instead, with a different constructor API. Fixed `targetinfo.lua` to use the real module — verified end-to-end that requests now round-robin across targets with no Lua errors.

## [1.3.1] - 2026-07-21

### Bumped
- proxy -> [v1.2.1](https://github.com/theta42/proxy/releases/tag/v1.2.1)
- sso-manager-node -> [v1.1.18](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.18)

proxy:

### Fixed
- The bootstrap anti-lockout admin account was always created as `proxyadmin2` regardless of `conf.auth.adminUsers`, while `migrations/permission_bootstrap.js` grants the global-admin permission to `conf.auth.adminUsers[0]`. If an operator customized `adminUsers` away from the default, the bootstrapped account and the permissioned account were two different (non-matching) usernames, so the anti-lockout account ended up with no admin access. `models/user_redis.js` now derives the bootstrap username from `conf.auth.adminUsers[0]` (falling back to `proxyadmin2`), matching `permission_bootstrap.js`.
- Corrected a `secrets.js.example` comment that claimed the bootstrap admin's password "defaults to the username itself" — it actually generates a random password printed to the container log on first boot.

### Changed
- Refreshed all README screenshots (hosts, per-host SSO auth, per-host basic auth) against the current UI, and added a new load-balancing screenshot for the multi-target feature.

sso-manager-node:

### Added
- N-Way Multi-Master LDAP replication: `LDAP_SERVER_ID` + `LDAP_REPLICATION_HOSTS` configure `syncrepl` peers in the bundled OpenLDAP, and a new `/sites` page (nav: **Sites**) shows each configured peer's LDAP URL and live reachability.
- A `location` property on users, editable from the profile and user-edit forms.

### Fixed
- `/sites` (added above) 500'd on every load: `views/sites.ejs` included nonexistent partials `header`/`footer` instead of this app's actual `top`/`bottom`. Fixed to match every other view.

### Changed
- Refreshed all README screenshots (dashboard, users, groups, OAuth apps) against the current UI, and added a new Sites & Replication screenshot.

### theta-env own changes
- Refreshed `docs/images/sso-dashboard.png` and `docs/images/proxy-hosts.png` to match the submodules' updated screenshots.

## [1.1.20] - 2026-07-20

### Bumped
- proxy -> [v1.1.17](https://github.com/theta42/proxy/releases/tag/v1.1.17)

proxy:

### Fixed
- An existing single-label subdomain host (e.g. `sso.nl.wgnode.com`) could not be attached to a wildcard cert added later (e.g. `*.nl.wgnode.com`): `Host.lookUpWildcardParent()` only checked the wildcard-as-child position (the wildcard's own base domain) and missed the far more common wildcard-as-sibling case, so the edit form's "Parent Wildcard" option stayed permanently greyed out. It now checks both positions, and a regression test covers the sibling case.

## [1.1.19] - 2026-07-18

### Bumped
- sso-manager-node -> [v1.1.17](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.17)

sso-manager-node:

### Added
- `conf.ldap.ldapsHost` and `conf.ldap.ldapsPort` config options for advertising a separate, internal-only LDAPS hostname on the `/integrations` page. Falls back to the public OAuth issuer host when unset.
- Contextual help panel on `/integrations` → LDAP explaining why LDAPS needs a hostname, why port 636 should not be forwarded publicly, and the recommended internal-DNS / Docker-internal alternatives.
- Tests for the `/integrations` route's LDAPS URL derivation and `ldapsHost` override.

### Changed
- `nodejs/package.json` / `package-lock.json` version bumped to `1.1.17`.
- `routes/index.js` now derives the displayed LDAPS URL from `conf.ldap.ldapsHost`/`ldapsPort` with fallback to the OAuth issuer host.
- `docs/configuration.md`, `docs/ldap.md`, `DEPLOYMENT.md`, and `secrets.js.example` document the new `ldapsHost`/`ldapsPort` options and recommended network layouts.

### theta-env own changes
- `setup.env.example` adds optional `CFG_LDAPS_HOST` for the internal LDAPS hostname.
- `setup.sh` passes `CFG_LDAPS_HOST` into the generated `./config/sso-secrets.js` as `ldap.ldapsHost`.
- `config.example/sso-secrets.js.example` documents `ldap.ldapsHost` / `ldap.ldapsPort`.
- `.env.example` adds `LDAPS_HOST` for legacy `.env` migrations.
- `docker-compose.yml` comments warn against forwarding 636 to the public internet.
- `README.md` explains the `CFG_LDAPS_HOST` recommendation in the port-forwarding section.

## [1.1.18] - 2026-07-18

### Bumped
- proxy -> [v1.1.16](https://github.com/theta42/proxy/releases/tag/v1.1.16)
- sso-manager-node -> [v1.1.16](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.16)

proxy:

### Changed
- Public-release packaging: removed `"private": true` from `nodejs/package.json`, corrected the repository URL to `https://github.com/theta42/proxy.git`, and fixed the MIT `LICENSE` copyright line.
- Genericized committed config defaults in `conf/base.js` and `conf/development.js` (`example.com` / `localhost` instead of theta42 infrastructure).
- The bootstrap `proxyadmin2` account now gets a random, one-time password when `auth.localAdminPass` is unset, instead of the well-known default.

### Security
- Sanitized rendered docs HTML with `xss` in `routes/docs.js`.
- The Unix socket JSON-RPC socket is now created with mode `660` instead of world-writable `777`.

### Fixed
- The global error handler no longer leaks `err.keys`, stack traces, or internal details in JSON responses.
- `DEPLOYMENT.md` and `docs/docker.md` now correctly describe the `CONF_SECRETS` env-var mechanism.

sso-manager-node:

### Security
- Hardened LDAP filter and DN construction against injection in `models/group_ldap.js` and `models/user_ldap.js`.
- Replaced `Math.random()`-based token/UUID/OTP generation with `crypto.randomUUID()` / `crypto.randomInt()` in `models/token.js`, `models/oauth_code.js`, and `models/oauth_client.js`.
- Refused startup when `oauth.jwtSecret` is missing or placeholder.
- Sanitized rendered docs/Terms-of-Service HTML with `xss` to block malicious markdown output.
- Removed full-object `console.log` of new-user data and reduced login error logging to `name`/`message` only.

### Changed
- Public-release packaging: removed `"private": true` from `nodejs/package.json` and bumped version to `1.1.16`.

### Fixed
- `models/email.js`: fixed from-address template rendering bug.

### theta-env own changes
- `CHANGELOG.md` now embeds the full app-level release notes for each submodule bump, not just links.
- `.env.example` no longer ships realistic-looking default passwords; values are clearly placeholders.
- `config.example/*.js.example` comments now describe the actual `CONF_SECRETS` env-var loading mechanism.
- `setup.sh` summary no longer prints generated passwords to stdout; it points to `./config/*.js`.
- `bootstrap/bootstrap.js` fails hard instead of falling back to weak default passwords when config is missing.

## [1.1.17] - 2026-07-18

### Bumped
- proxy -> [v1.1.15](https://github.com/theta42/proxy/releases/tag/v1.1.15)
- sso-manager-node -> [v1.1.15](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.15)

Both apps' bare-metal `install.sh` now installs to `/opt/theta42/<app>` and seeds `/etc/<app>/secrets.js` on first run, matching a `wget -O - .../install.sh | sudo bash` one-line install for both (previously proxy-only); re-running it prints the version it's updating from/to. sso-manager-node's installer was rewritten from a flag-driven, copy-based script into the same idempotent git-clone pattern proxy already used, and now bootstraps OpenLDAP itself on first run instead of requiring the repo to already be checked out locally. None of this affects the Docker/unified-stack deployment this repo orchestrates — bare-metal-only.

## [1.1.16] - 2026-07-18

### Bumped
- proxy -> [v1.1.14](https://github.com/theta42/proxy/releases/tag/v1.1.14)
- sso-manager-node -> [v1.1.14](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.14)

Both: bumped `@simpleworkjs/conf` to 1.2.0 and `jq-repeat` to 2.2.0.

### Changed
- `./config/sso-secrets.js` and `./config/proxy-secrets.js` are now loaded via each app's `CONF_SECRETS` env var (set by the entrypoint) instead of being symlinked into `/app/conf/secrets.js` — neither container needs write access to its own `conf/` directory anymore. No change to the config file format or bind mounts; existing `./config/` directories keep working as-is.

## [1.1.15] - 2026-07-17

### Bumped
- proxy -> [v1.1.13](https://github.com/theta42/proxy/releases/tag/v1.1.13)
- sso-manager-node -> [v1.1.13](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.13)

proxy:

### Fixed
- The host edit form's "Parent Wildcard" option stayed greyed out even when a valid wildcard actually existed for that host, so an already-created host could never be switched onto one from the edit modal (only brand-new hosts, via the field's `keyup` handler, ever saw it become available). The underlying `/host/lookup/:item` check also had the same self-match issue as the recently-fixed backend bug: it resolved an already-existing host to its own record instead of a sibling wildcard. Added a dedicated `/host/wildcard-parent/:item` endpoint that checks both directions, and the edit form now actually runs the check when it opens.
- Fixed an nginx startup warning: `the "listen ... http2" directive is deprecated, use the "http2" directive instead`. Migrated to the standalone `http2 on;` directive (nginx 1.25.1+).

### Added
- Four new plain-language docs aimed at less technical readers, replacing the system-design-level Architecture/Installation docs as the target of most card help links: **Hosts & HTTPS**, **DNS Providers**, **Users, Groups & Permissions**, and **API Tokens**. Each links onward to the deeper technical reference for readers who want it; the technical docs link back the other way too. The personal-access-token card (previously missed entirely) now has a help link.

### Fixed
- The in-app docs viewer rendered every `docs/*.md` page with a garbled heading and a stray horizontal rule at the top — Jekyll front matter (meant only for the GitHub Pages build) was never stripped before being handed to the markdown renderer. Also fixed: cross-doc links never resolved in-app, since this viewer serves docs at `/docs/<slug>` with no `.html` suffix — they're now rewritten to the correct in-app URL (by registered slug, falling back to the doc's real filename), the same way image paths already were.

sso-manager-node:

### Added
- Three new plain-language docs aimed at less technical readers, replacing the schema-level LDAP/OAuth/API docs as the target of most card help links: **Accounts, Groups & Managers**, **Connecting Apps (SSO)**, and **API Tokens**. Each links onward to the deeper technical reference for readers who want it; the technical docs link back the other way too. The personal-access-token card (previously missed) now links to its own doc.

### Fixed
- The in-app docs viewer rendered every `docs/*.md` page with a garbled heading and a stray horizontal rule at the top — Jekyll front matter (meant only for the GitHub Pages build) was never stripped before being handed to the markdown renderer. Also fixed: cross-doc links (`ldap.html`, `index.html`, etc.) never resolved in-app, since this viewer serves docs at `/docs/<slug>` with no `.html` suffix — they're now rewritten to the correct in-app URL, the same way image paths already were.
- The new concept docs' cross-links (`concepts-accounts.html` etc.) are the correct, working URL on the Jekyll/GitHub Pages build (where the page's URL is its filename stem) but didn't resolve in the in-app docs viewer, which serves docs at a separate short slug (`/docs/accounts`). The in-app renderer now also resolves a doc's real filename as a fallback, so one link written in a doc works on both targets.

## [1.1.14] - 2026-07-17

### Bumped
- proxy -> [v1.1.11](https://github.com/theta42/proxy/releases/tag/v1.1.11)
- sso-manager-node -> [v1.1.11](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.11)

Both: moved the help (❓) link out of the global header and onto each relevant card individually, so it deep-links straight to the doc that actually covers that card instead of one generic per-page guess.

## [1.1.13] - 2026-07-17

### Bumped
- proxy -> [v1.1.10](https://github.com/theta42/proxy/releases/tag/v1.1.10)
- sso-manager-node -> [v1.1.10](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.10)

Both: added a help icon (❓) in the top-right header that deep-links to the doc most relevant to the current page, and made the in-app docs viewer (`/docs`) searchable (a simple line-substring search over the local doc set, no new dependency, still works with no internet access).

## [1.1.12] - 2026-07-17

### Bumped
- proxy -> [v1.1.9](https://github.com/theta42/proxy/releases/tag/v1.1.9)

proxy:

### Added
- The host list now shows who created each host, and when.
- Plain (non-wildcard) hosts can now be renamed after creation — the hostname field is no longer permanently locked. Wildcard hosts, wildcard children, and auto-created subdomain cache entries stay locked, since other records reference them by name.
- More inline help text on the host create/edit form (Target SSL, wildcard matching behavior).

### Fixed
- The host create/edit modal's tabs could overflow awkwardly on narrow (mobile) screens — they now scroll horizontally instead.
- Fixed a bug in the vendored `model-redis` library's record-rename path: renaming a record's primary key while another `always`-type field (e.g. `updated_on`) is defined earlier in the schema left a stray, incomplete hash behind under the old key, making that name permanently unavailable for reuse. Worked around in `Host.prototype.update()`.

## [1.1.11] - 2026-07-17

### Bumped
- proxy -> [v1.1.8](https://github.com/theta42/proxy/releases/tag/v1.1.8)

proxy:

### Fixed
- **Couldn't attach an existing host to a parent wildcard.** The host edit form's "Parent Wildcard" option submitted correctly, but `Host.prototype.update()` had no `challengeType` handling at all (only `Host.create()` did) — selecting it and saving silently did nothing. Added the same wildcard-parent lookup to `update()`.
- **Couldn't register a wildcard's own base domain as a host.** A wildcard cert's `altNames` already cover both the base domain and `*.base domain`, but the lookup tree stores the wildcard one level below its base domain, and a lookup for the bare base domain landed on that empty parent node and found nothing — even though the already-issued cert covers it. `buildLookUpObj()` now also stamps the parent node so this resolves correctly, without re-issuing or duplicating the cert.

## [1.1.10] - 2026-07-17

### Bumped
- sso-manager-node -> [v1.1.9](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.9)

sso-manager-node:

### Added
- Every account's personal Unix group (its primary GID holder) can now have supplementary members managed from the account's profile page ("Members of `<uid>`'s group", admin-only) — e.g. to share write access to files owned by that group. Uses the standard `memberUid` attribute (RFC 2307 `posixGroup`).

## [1.1.9] - 2026-07-17

### Bumped
- sso-manager-node -> [v1.1.8](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.8)

sso-manager-node:

### Added
- Group membership is now editable directly from a user's profile page ("My groups" -- add via a group-name picker, remove with a button per row), instead of only from each group's own card on the Groups page. Admin-only, using the existing per-group member add/remove endpoints.

### Fixed
- The Edit Profile form's Mobile Phone field had a stray `validate=":9"` making it effectively required (submission was blocked with "Please fix the form errors" if left blank) -- it was always meant to be optional, matching the "Add user" form. Removed.
- A service account's profile always showed `Name: Service Account` -- every service account has the same literal filler given/last name (a schema-satisfying placeholder, not meant to be shown), making them indistinguishable by name. The Name line is now hidden for service accounts.
- The Users page's Service Accounts tab, and a freshly-created service account's own profile, could appear empty/not-a-service-account for up to 5 minutes right after creation. Creating a user caches it via `User.get()` *before* the route handler marks it as a service account (group membership), so the cached copy had `isServiceAccount` stuck wrong until the cache TTL expired. Now cleared and re-fetched immediately after marking.
- A user belonging to exactly one LDAP group had their `memberOf` attribute returned as a bare string instead of a one-element array (ldapts's normal behavior for single-valued attributes) -- client-side permission checks (`for(let group of user.memberOf)`) would then iterate the DN character-by-character instead of once, causing pages gated on that group (e.g. Groups) to incorrectly show "You do not have permission to be here." Normalized `memberOf` to always be an array, same fix already applied to `manager`.

## [1.1.8] - 2026-07-17

### Bumped
- sso-manager-node -> [v1.1.7](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.7)

sso-manager-node:

### Changed
- **Service accounts unified to one kind.** Removed the LDAP bind-only service account type (the Integrations → LDAP "Service Accounts" card, and its `/api/service-account` routes) -- every service account is now a real Unix/POSIX account with a UID, created from the new **Users → Service Accounts** tab. Email and password are both optional for service accounts; a blank password means no `userPassword` is set at all (the account simply can't bind).
- **Added a `manager` field to every account.** Multi-valued (a list of usernames), defaults to whoever created the account (the admin who added it, or whoever sent the invite), and reassignable from the account's Edit form. Anyone listed as a manager can edit that account -- same fields an admin can (mobile, description, SSH key, date of birth, home directory, login shell, manager list) -- without needing `app_sso_admin`.
- `homeDirectory` and `loginShell` are now editable from the Edit Profile form (previously view-only).

## [1.1.7] - 2026-07-16

### Bumped
- proxy -> [v1.1.7](https://github.com/theta42/proxy/releases/tag/v1.1.7)
- sso-manager-node -> [v1.1.6](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.6)

Both: redesigned the GitHub Pages docs site to match each app's own look (dark navbar/footer, Bootstrap 5, Font Awesome) instead of the generic `jekyll-theme-cayman` theme, added a real cross-page nav, SEO (`jekyll-seo-tag` + `jekyll-sitemap`), and mobile-responsive layout. theta-env's own docs site got the same treatment in this release too (see below).

### Changed
- theta-env's own docs site redesigned the same way -- dark navbar/footer using the shared theta42 logo (this repo has no app UI of its own), cross-page nav, SEO, mobile-responsive. `docs/index.md`'s "More docs" section removed (redundant with the new nav).
- Added `docs/_site` to `.gitignore` (missing entirely before).

## [1.1.6] - 2026-07-16

### Bumped
- proxy -> [v1.1.6](https://github.com/theta42/proxy/releases/tag/v1.1.6)

proxy: Hosts admin UI's Authentication tab radios (Off / Basic / SSO) had no shared `name`, so clicking one didn't uncheck the others. Added `name="auth_mode"` to restore standard exclusive radio-group behavior.

## [1.1.5] - 2026-07-16

### Bumped
- proxy -> [v1.1.5](https://github.com/theta42/proxy/releases/tag/v1.1.5)
- sso-manager-node -> [v1.1.5](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.5)

Both: bumped `jq-repeat` 2.0.1 -> 2.1.0. proxy fixed real breakage from the removed `__setPut`/`__setTake` API (insert/remove row hooks in the admin UI); sso-manager-node fixed a stale-data flash in the edit-profile flow caused by `update()`'s new throttling.

## [1.1.4] - 2026-07-16

### Added
- White-label support in both proxy and sso-manager-node -- `<title>`, navbar brand, and logo are now conf-driven (`conf.name`/`conf.logo`) instead of hardcoded. Closes [proxy#45](https://github.com/theta42/proxy/issues/45) and [sso-manager-node#6](https://github.com/theta42/sso-manager-node/issues/6).

### Fixed
- sso-manager-node: the bundled default LDAP ppolicy had `pwdLockout: FALSE`, silently making "deactivate user" not actually block login. Fixed, with a drift-correction path for already-deployed instances.

### Bumped
- proxy -> [v1.1.4](https://github.com/theta42/proxy/releases/tag/v1.1.4)
- sso-manager-node -> [v1.1.4](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.4)

## [1.1.3] - 2026-07-16

### Added
- `CHANGELOG.md` (this file). Closes [#43](https://github.com/theta42/theta-env/issues/43).

### Bumped
- proxy -> [v1.1.3](https://github.com/theta42/proxy/releases/tag/v1.1.3)
- sso-manager-node -> [v1.1.3](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.3)

## [1.1.2] - 2026-07-16

### Changed
- `docs/index.md` (the published site's home page) never linked to `architecture.md`, `quickstart.md`, or `standalone.md` — added a "More docs" section so they're reachable from the site instead of only by direct URL.

### Bumped
- proxy -> [v1.1.2](https://github.com/theta42/proxy/releases/tag/v1.1.2)
- sso-manager-node -> [v1.1.2](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.2)

## [1.1.1] - 2026-07-16

### Changed
- `setup.sh` now pins `proxy` and `sso-manager-node` to their latest release tag (`vX.Y.Z`) instead of the tip of `master`. A rebuild now always lands on a tagged, versioned release of each app rather than whatever was most recently merged upstream.

### Bumped
- proxy -> [v1.1.1](https://github.com/theta42/proxy/releases/tag/v1.1.1)
- sso-manager-node -> [v1.1.1](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.1)

## [1.1.0] - 2026-07-16

First tagged release. Establishes the `vX.Y.Z` tag convention going forward.

### Added
- `setup.sh` now reports which submodules actually moved to a newer commit during an update, instead of updating silently.

### Bumped
- proxy -> [v1.1.0](https://github.com/theta42/proxy/releases/tag/v1.1.0)
- sso-manager-node -> [v1.1.0](https://github.com/theta42/sso-manager-node/releases/tag/v1.1.0)

[Unreleased]: https://github.com/theta42/theta-env/compare/v1.1.20...HEAD
[1.1.17]: https://github.com/theta42/theta-env/compare/v1.1.16...v1.1.17
[1.1.16]: https://github.com/theta42/theta-env/compare/v1.1.15...v1.1.16
[1.1.15]: https://github.com/theta42/theta-env/compare/v1.1.14...v1.1.15
[1.1.14]: https://github.com/theta42/theta-env/compare/v1.1.13...v1.1.14
[1.1.13]: https://github.com/theta42/theta-env/compare/v1.1.12...v1.1.13
[1.1.12]: https://github.com/theta42/theta-env/compare/v1.1.11...v1.1.12
[1.1.11]: https://github.com/theta42/theta-env/compare/v1.1.10...v1.1.11
[1.1.10]: https://github.com/theta42/theta-env/compare/v1.1.9...v1.1.10
[1.1.9]: https://github.com/theta42/theta-env/compare/v1.1.8...v1.1.9
[1.1.8]: https://github.com/theta42/theta-env/compare/v1.1.7...v1.1.8
[1.1.7]: https://github.com/theta42/theta-env/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/theta42/theta-env/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/theta42/theta-env/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/theta42/theta-env/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/theta42/theta-env/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/theta42/theta-env/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/theta42/theta-env/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/theta42/theta-env/releases/tag/v1.1.0
