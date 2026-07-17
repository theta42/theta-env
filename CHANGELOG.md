# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
correspond to git tags (`vX.Y.Z`). Entries here cover theta-env's own
orchestration code; see each submodule's own `CHANGELOG.md`
([proxy](https://github.com/theta42/proxy/blob/master/CHANGELOG.md),
[sso-manager-node](https://github.com/theta42/sso-manager-node/blob/master/CHANGELOG.md))
for what changed inside the apps it composes.

## [Unreleased]

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

[Unreleased]: https://github.com/theta42/theta-env/compare/v1.1.12...HEAD
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
