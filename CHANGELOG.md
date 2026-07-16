# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
correspond to git tags (`vX.Y.Z`). Entries here cover theta-env's own
orchestration code; see each submodule's own `CHANGELOG.md`
([proxy](https://github.com/theta42/proxy/blob/master/CHANGELOG.md),
[sso-manager-node](https://github.com/theta42/sso-manager-node/blob/master/CHANGELOG.md))
for what changed inside the apps it composes.

## [Unreleased]

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

[Unreleased]: https://github.com/theta42/theta-env/compare/v1.1.3...HEAD
[1.1.3]: https://github.com/theta42/theta-env/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/theta42/theta-env/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/theta42/theta-env/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/theta42/theta-env/releases/tag/v1.1.0
