# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
correspond to git tags (`vX.Y.Z`). Entries here cover theta-env's own
orchestration code; see each submodule's own `CHANGELOG.md`
([proxy](https://github.com/theta42/proxy/blob/master/CHANGELOG.md),
[sso-manager-node](https://github.com/theta42/sso-manager-node/blob/master/CHANGELOG.md))
for what changed inside the apps it composes.

## [Unreleased]

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

[Unreleased]: https://github.com/theta42/theta-env/compare/v1.1.8...HEAD
[1.1.8]: https://github.com/theta42/theta-env/compare/v1.1.7...v1.1.8
[1.1.7]: https://github.com/theta42/theta-env/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/theta42/theta-env/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/theta42/theta-env/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/theta42/theta-env/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/theta42/theta-env/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/theta42/theta-env/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/theta42/theta-env/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/theta42/theta-env/releases/tag/v1.1.0
