#!/usr/bin/env bash
#
# theta-suite setup — one-command bring-up of the unified SSO Manager + Proxy stack.
#
#   git clone --recursive <theta-suite> && cd theta-suite
#   cp setup.env.example setup.env   # set CFG_DOMAIN to your domain (once)
#   ./setup.sh            # first run: generates ./config/ from setup.env, builds + bootstraps + starts
#   ./setup.sh            # later runs: rebuilds + bootstraps + starts (config left untouched)
#
# Idempotent: safe to re-run. It pulls its own latest version, updates the two
# submodules, manages config in a bind-mounted ./config/ directory
# (sso-secrets.js + proxy-secrets.js — NO .env / proxy.env), snapshots state
# before rebuild, (re)starts the SSO Manager, runs the bootstrap (which
# converges the LDAP service account / first admin / OAuth client to the ./config
# values and writes the generated OAuth client creds into proxy-secrets.js),
# then starts the proxy and registers the SSO's + proxy's own hostnames as
# Host records in it (otherwise the proxy has no route for either). A single
# `./setup.sh` run is enough to bring an existing deployment fully up to date —
# no manual `git pull` needed first.
#
# What it does, in order:
#   0. Pull theta-suite's own latest commit (fast-forward only) and, if it
#      moved, re-exec so the rest of this run uses the new script. Never
#      blocks the run — skips silently with no upstream, warns and continues
#      on any other pull failure (offline, local changes). Skip with
#      SKIP_SELF_UPDATE=1.
#   1. Update the git submodules to the latest of their tracked remote branch
#      (so each run builds the newest sso-manager-node + proxy). Skip with
#      SKIP_SUBMODULE_UPDATE=1.
#   2. ensure_config: create ./config/sso-secrets.js + proxy-secrets.js if
#      missing. On a fresh clone the domain/hosts are read from ./setup.env
#      (the one place the domain is entered, as a plain DNS domain — the LDAP
#      base DN is derived from it) and both files are generated with that
#      domain filled in everywhere + random secrets, then the run proceeds to
#      build (no edit-and-re-run step). On
#      an existing deployment with .env/proxy.env, the secrets are migrated
#      (preserved) into ./config. If ./config already exists it is left
#      untouched (the operator owns it; setup.env is ignored).
#   3. backup_before_rebuild: snapshot ./config + LDAP (slapcat) + both Redis
#      (BGSAVE + dump.rdb) to ./backups/<ts>/ before the rebuild. No-op on the
#      very first run. Keeps the last BACKUP_KEEP (default 5).
#   4. docker compose up -d --build sso-manager; wait for /health.
#   5. docker compose exec sso-manager node /bootstrap/bootstrap.js
#      -> creates/updates the LDAP service account, first admin, OAuth client;
#         writes the OAuth client creds into ./config/proxy-secrets.js; prints
#         CLIENT_ID / CLIENT_SECRET / ALREADY_CONFIGURED on stdout. Also seeds
#         the SSO directory with the stack's own resources (site -> host ->
#         SSO Manager + Proxy services, with the proxy's OAuth client linked
#         under its service) so the Directory page is populated out of the
#         box. Idempotent — existing slugs are operator-owned and left alone.
#   6. docker compose up -d --build proxy; wait for /health.
#   7. Register <SSO_HOST> and <PROXY_HOST> as Host records in the proxy (via
#      `docker compose exec proxy node`, calling the proxy's Host model
#      directly) so the proxy actually routes those hostnames somewhere —
#      nothing else creates them. Idempotent; skips a host that already exists.
#   8. Print the first-admin login + the public URLs.
#
# Requires: git, docker + docker compose (v1 standalone or v2 plugin).

set -euo pipefail

cd "$(dirname "$0")"

CFG_ADMIN_PASS="${CFG_ADMIN_PASS:-}"
CONFIG_DIR=./config
BACKUP_DIR=./backups
BACKUP_KEEP="${BACKUP_KEEP:-5}"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# Escape a value for a single-quoted JS string: \ -> \\, ' -> \', then wrap in '...'.
js_str() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\'/\\\'}"
	printf "'%s'" "$s"
}

# Random hex (openssl if available, else /dev/urandom).
rand_hex() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "${1:-32}"
	else
		head -c "$((${1:-32} / 2 + 1))" /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-$((2 * ${1:-32}))
	fi
}

# Upsert KEY=VALUE into ./.env, which `docker compose` auto-loads for every
# future invocation in this directory. Used to persist the *_GIT_COMMIT build
# args (see SSO_GIT_COMMIT/PROXY_GIT_COMMIT/JUMP_GIT_COMMIT below) so that an
# ad-hoc `docker compose up --build <service>` run later, OUTSIDE this script,
# still resolves the right commit instead of silently baking "unknown" (the
# submodule .git pointer file can't be resolved from inside the build
# context, so the value must come from the host via this file or the export).
env_upsert() {
	local key="$1" val="$2" file=./.env
	touch "$file"
	if grep -q "^${key}=" "$file" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${val}|" "$file"
	else
		printf '%s=%s\n' "$key" "$val" >> "$file"
	fi
}

# Detect docker compose (v2 plugin `docker compose` or v1 standalone `docker-compose`).
if docker compose version >/dev/null 2>&1; then
	COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
	COMPOSE=(docker-compose)
else
	die "docker compose not found. Install Docker Compose (v2 plugin or v1 standalone)."
fi

# Is a named container running? (compose-independent check.)
running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# Parse a KEY=VALUE file into the environment the way `docker compose` does:
# the value is everything after the FIRST '=' (so `ORG_NAME=My Org` works),
# outer wrapping quotes are stripped, blank/#/no-=/invalid-identifier lines
# are skipped. No shell expansion/eval is performed on values.
parse_kv_file() {
	local file="$1" line key val qc
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line#"${line%%[![:space:]]*}"}"
		[[ -z "$line" || "${line:0:1}" == '#' ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		val="${line#*=}"
		[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
		if [[ ${#val} -ge 2 ]]; then
			qc="${val:0:1}"
			if { [[ "$qc" == '"' || "$qc" == "'" ]] && [[ "${val: -1}" == "$qc" ]]; }; then
				val="${val:1:${#val}-2}"
			fi
		fi
		export "$key=$val"
	done < "$file"
}

# ── 0. Self-update: pull theta-suite itself, then restart with the new version ──
# Step 1 below only refreshes the proxy/sso-manager-node submodules — it never
# updates setup.sh or this repo's own files. Pull the current branch's
# upstream (fast-forward only) before anything else, and if it moved, re-exec
# so the rest of THIS run uses the freshly-pulled script rather than the copy
# already read into memory. Never blocks the run: skips silently if this
# isn't a git checkout, is on a detached HEAD, or has no upstream configured;
# warns (but continues on the current checkout) if the pull fails for any
# other reason (offline, local changes that prevent a fast-forward). Skip
# entirely with SKIP_SELF_UPDATE=1.
if [[ "${SKIP_SELF_UPDATE:-0}" != "1" && "${THETA_SUITE_REEXECED:-0}" != "1" ]] \
	&& command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	&& git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1
then
	BEFORE_REV="$(git rev-parse HEAD)"
	BEFORE_VER="$(git describe --tags "$BEFORE_REV" 2>/dev/null || echo "${BEFORE_REV:0:12}")"
	if git pull --ff-only -q; then
		AFTER_REV="$(git rev-parse HEAD)"
		if [[ "$BEFORE_REV" != "$AFTER_REV" ]]; then
			AFTER_VER="$(git describe --tags "$AFTER_REV" 2>/dev/null || echo "${AFTER_REV:0:12}")"
			info "Updated theta-suite (${BEFORE_VER} -> ${AFTER_VER}) — restarting setup.sh with the new version..."
			THETA_SUITE_REEXECED=1 exec "$0" "$@"
		fi
	else
		warn "Could not fast-forward theta-suite to the latest upstream (offline, or local changes) — continuing with the current checkout."
	fi
fi

# ── Jump host hostname (always installed) ─────────────────────────────────────
# The SSH jump host is a core component — always built + started (no longer
# gated by CFG_JUMP_HOST_ENABLED). Read its optional hostname override from
# ./setup.env now (before the submodule loop and the compose steps) so the
# later steps can use it. The authoritative CFG_* for secrets are still
# resolved in ensure_config; this is only the hostname override.
[[ -f ./setup.env ]] && parse_kv_file ./setup.env
export CFG_JUMP_HOST

# ── Optional outbound HTTP(S) proxy for docker build + the running containers ─
# CFG_HTTP_PROXY / CFG_HTTPS_PROXY / CFG_NO_PROXY (from ./setup.env or the
# environment) — NOT the theta42 "proxy" app; this is an upstream HTTP proxy
# for reaching the internet (npm/apt during image builds, and SMTP/ACME/DNS
# provider calls at runtime), useful on isolated/offline/corporate-network
# test hosts. Off by default. docker-compose.yml passes these through as both
# build args (Docker also recognizes them as predefined build ARGs) and
# container environment on every service, so one setup.env entry covers the
# whole stack.
export CFG_HTTP_PROXY="${CFG_HTTP_PROXY:-}"
export CFG_HTTPS_PROXY="${CFG_HTTPS_PROXY:-${CFG_HTTP_PROXY:-}}"
export CFG_NO_PROXY="${CFG_NO_PROXY:-localhost,127.0.0.1,sso-manager,proxy,jump-host}"
if [[ -n "$CFG_HTTP_PROXY" ]]; then
	info "Using HTTP proxy for docker build + containers: $CFG_HTTP_PROXY"
fi

# ── 1. Update submodules to their latest release tag, verify build contexts ───
# Submodules track release tags (vX.Y.Z), not the tip of master -- so
# "update" means "move to the newest tag", not "move to the newest commit".
# `git submodule update --init --recursive` (no --remote) only clones a
# missing submodule at its currently-pinned commit; it never advances it on
# its own, so the per-submodule tag resolution below is what actually moves
# proxy/sso-manager-node forward.
if [[ "${SKIP_SUBMODULE_UPDATE:-0}" != "1" ]]; then
	if ! command -v git >/dev/null 2>&1; then
		die "git not found. Install git, or set SKIP_SUBMODULE_UPDATE=1 to build the pinned submodule commits."
	fi
	if ! git submodule update --init --recursive 2>&1; then
		die "git submodule update --init failed. Run manually: git submodule update --init --recursive"
	fi

	# jump-host is a core component — always tracked + built.
	SUBMODULES=(sso-manager-node proxy jump-host)
	info "Updating submodules to their latest release tag (${SUBMODULES[*]})..."
	for sm in "${SUBMODULES[@]}"; do
		[[ -d "$sm" ]] || continue
		before_rev="$(git -C "$sm" rev-parse HEAD 2>/dev/null || true)"
		# Prefer the exact tag the submodule is currently pinned to; fall back
		# to a short commit hash if it's on an untagged commit (shouldn't
		# normally happen -- this repo only ever pins tagged releases).
		before_tag="$(git -C "$sm" describe --tags --exact-match "$before_rev" 2>/dev/null || echo "${before_rev:0:12}")"

		if ! git -C "$sm" fetch --tags -q 2>&1; then
			warn "  ${sm}: could not fetch tags (offline?) — staying on ${before_tag}."
			continue
		fi

		latest_tag="$(git -C "$sm" tag --list 'v*' --sort=-v:refname | head -n1)"
		if [[ -z "$latest_tag" ]]; then
			warn "  ${sm}: no vX.Y.Z release tags found — staying on ${before_tag}."
			continue
		fi

		if ! git -C "$sm" checkout -q "$latest_tag" 2>&1; then
			warn "  ${sm}: could not check out ${latest_tag} — staying on ${before_tag}."
			continue
		fi

		after_rev="$(git -C "$sm" rev-parse HEAD 2>/dev/null || true)"
		if [[ "$before_rev" != "$after_rev" ]]; then
			info "  ${sm}: updated ${before_tag} -> ${latest_tag}"
		else
			info "  ${sm}: already up to date (${latest_tag})"
		fi
	done
else
	info "Skipping submodule update (SKIP_SUBMODULE_UPDATE=1)."
fi

[[ -f sso-manager-node/Dockerfile.openldap ]] \
	|| die "sso-manager-node/Dockerfile.openldap missing. Run: git submodule update --init --recursive"
[[ -f proxy/Dockerfile ]] \
	|| die "proxy/Dockerfile missing. Run: git submodule update --init --recursive"

# ── 2. ensure_config ──────────────────────────────────────────────────────────
# Derive a DNS domain from a base DN (dc=foo,dc=bar -> foo.bar). Only used to
# read domain back out of a base DN set directly (advanced override, or an
# old setup.env / migrated .env) — the normal path is dn_from_domain below.
domain_from_dn() {
	echo "$1" | sed 's/^dc=//; s/,dc=/./g'
}

# Derive an LDAP base DN from a DNS domain (foo.bar -> dc=foo,dc=bar). This is
# the normal path: operators enter a plain domain in setup.env (CFG_DOMAIN),
# and the base DN is built from it, however many labels it has (a DuckDNS
# domain like foo.duckdns.org becomes dc=foo,dc=duckdns,dc=org — LDAP doesn't
# care how many dc= components there are).
dn_from_domain() {
	echo "dc=$1" | sed 's/\./,dc=/g'
}

# Write ./config/sso-secrets.js from the CFG_* shell vars.
write_sso_secrets() {
	local dn="$CFG_BASE_DN" domain="$CFG_DOMAIN"
	[[ -n "$domain" ]] || domain="$(domain_from_dn "$dn")"
	cat > "$CONFIG_DIR/sso-secrets.js" <<SSOEOF
'use strict';
// Generated by setup.sh. Edit freely; re-run ./setup.sh to apply.
// The SSO app reads this via @simpleworkjs/conf (CONF_SECRETS env var).
// The app ignores the extra stack/bootstrap/serviceAccountPass keys (read by
// the orchestrator). Back this file up off-host — it holds all SSO secrets.

module.exports = {
	name: $(js_str "$CFG_ORG"),
	ldap: {
		url: 'ldap://localhost:389',
		bindDN: $(js_str "cn=admin,${dn}"),
		bindPassword: $(js_str "$CFG_LDAP_ADMIN_PASS"),
		userBase: $(js_str "ou=people,${dn}"),
		groupBase: $(js_str "ou=groups,${dn}"),
		ldapsHost: $(js_str "${CFG_LDAPS_HOST:-}"),
		ldapsPort: 636,
	},
	smtp: {
		host: $(js_str "${CFG_SMTP_HOST:-}"),
		port: ${CFG_SMTP_PORT:-587},
		secure: false,
		user: $(js_str "${CFG_SMTP_USER:-}"),
		pass: $(js_str "${CFG_SMTP_PASS:-}"),
		from: $(js_str "${CFG_SMTP_FROM:-${CFG_ORG} <noreply@${domain}>}"),
	},
	oauth: {
		issuer: $(js_str "https://${CFG_SSO_HOST}"),
		jwtSecret: $(js_str "$CFG_JWT_SECRET"),
		token_lifetime: { access_token: 3600, refresh_token: 2592000 },
	},
	// Without this, @simpleworkjs/orm falls back to './config/inventory.sqlite'
	// relative to the app's /app cwd -- inside the container's ephemeral layer,
	// not any mounted volume -- so every Resource/site/host/service/oauth row
	// (the whole Directory Management page) would be silently wiped on every
	// container recreate. /data is already a persisted volume (Redis lives
	// there too), so this just co-locates the sqlite file with it.
	orm: {
		dialect: 'sqlite',
		storage: '/data/inventory.sqlite',
	},

	// ── Orchestrator-only (ignored by the app) ───────────────────────────────
	stack: {
		ldapBaseDn: $(js_str "$dn"),
		ldapDomain: $(js_str "$domain"),
		siteName: $(js_str "${CFG_SITE_NAME:-local}"),
		ldapCertCn: $(js_str "${CFG_LDAP_CERT_CN:-}"),
		ssoHost: $(js_str "$CFG_SSO_HOST"),
		proxyHost: $(js_str "$CFG_PROXY_HOST"),
	},
	bootstrap: {
		adminUid: $(js_str "$CFG_ADMIN_UID"),
		adminPass: $(js_str "$CFG_ADMIN_PASS"),
		adminEmail: $(js_str "$CFG_ADMIN_EMAIL"),
	},
	serviceAccountPass: $(js_str "$CFG_SVC_PASS"),
};
SSOEOF
}

# Write ./config/proxy-secrets.js from the CFG_* shell vars. clientId/clientSecret
# are placeholders; the bootstrap writes the generated values back into this file.
write_proxy_secrets() {
	local dn="$CFG_BASE_DN"
	cat > "$CONFIG_DIR/proxy-secrets.js" <<PROXYEOF
'use strict';
// Generated by setup.sh. The proxy reads this via @simpleworkjs/conf (CONF_SECRETS
// env var). clientId/clientSecret are filled in by the bootstrap
// (run by ./setup.sh) — leave them as-is. ldap.bindPassword MUST equal
// serviceAccountPass in sso-secrets.js (the proxy binds as that account).

module.exports = {
	oidc: {
		enabled: true,
		issuer: $(js_str "https://${CFG_SSO_HOST}"),
		authorizationEndpoint: $(js_str "https://${CFG_SSO_HOST}/oauth/authorize"),
		tokenEndpoint: 'http://sso-manager:3001/oauth/token',
		userinfoEndpoint: 'http://sso-manager:3001/oauth/userinfo',
		endSessionEndpoint: $(js_str "https://${CFG_SSO_HOST}/oauth/logout"),
		clientId: $(js_str "$CFG_CLIENT_ID"),
		clientSecret: $(js_str "$CFG_CLIENT_SECRET"),
		redirectUri: $(js_str "https://${CFG_PROXY_HOST}/api/auth/oidc/callback"),
		scopes: ['openid', 'profile', 'email', 'groups'],
		groupsClaim: 'groups',
		usernameClaim: 'preferred_username',
	},
	ldap: {
		url: 'ldaps://sso-manager:636',
		bindDN: $(js_str "cn=ldapclient,ou=people,${dn}"),
		bindPassword: $(js_str "$CFG_SVC_PASS"),
		searchBase: $(js_str "ou=people,${dn}"),
		userFilter: '(objectClass=posixAccount)',
		userNameAttribute: 'uid',
		tlsOptions: { rejectUnauthorized: false },
	},
	auth: {
		adminGroups: ['app_sso_admin'],
		adminUsers: ['proxyadmin2'],
		groupRoleMap: {},
		// Initial password for the local anti-lockout admin (proxyadmin2) —
		// only read by the proxy the first time that account is created;
		// changing it here later has no effect on an already-created account.
		localAdminPass: $(js_str "$CFG_PROXY_ADMIN_PASS"),
	},
	stack: {
		ssoHost: $(js_str "$CFG_SSO_HOST"),
		proxyHost: $(js_str "$CFG_PROXY_HOST"),
	},
};
PROXYEOF
}

ensure_config() {
	if [[ ! -f "$CONFIG_DIR/openbao.hcl" ]]; then
		info "Generating $CONFIG_DIR/openbao.hcl ..."
		mkdir -p "$CONFIG_DIR"
		cat > "$CONFIG_DIR/openbao.hcl" <<BAOEOF
storage "file" {
  path = "/vault/data"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}
disable_mlock = true
ui = true
BAOEOF
		chmod 644 "$CONFIG_DIR/openbao.hcl"
	fi

	if [[ -f "$CONFIG_DIR/sso-secrets.js" ]]; then
		info "Using existing $CONFIG_DIR/sso-secrets.js (operator-owned — left untouched)."
		return 0
	fi

	# First run: read the domain/hosts from ./setup.env — the ONE place the
	# domain is entered (e.g. 718it.biz), as a plain DNS domain; the LDAP base
	# DN is derived from it (dc=718it,dc=biz). Hostnames default to
	# sso.<domain> / proxy.<domain>, also derived from it. setup.env is
	# used ONLY on first run; once ./config/*.js exist they are operator-owned
	# and setup.env is ignored. Falls back to legacy .env/proxy.env migration
	# below for existing deployments.
	if [[ -f ./setup.env ]]; then
		info "Reading domain/hosts from ./setup.env ..."
		parse_kv_file ./setup.env
	fi

	# Bind the CFG_* vars to empty where setup.env / the environment didn't set
	# them, so the .env migration's `${LDAP_X:-$CFG_X}` defaults below don't trip
	# `set -u`. Real values come from setup.env, the .env migration, or the
	# derivation block further down (no example.com placeholders here).
	CFG_BASE_DN="${CFG_BASE_DN:-}"
	CFG_DOMAIN="${CFG_DOMAIN:-}"
	CFG_SITE_NAME="${CFG_SITE_NAME:-}"
	CFG_ORG="${CFG_ORG:-}"
	CFG_SSO_HOST="${CFG_SSO_HOST:-}"
	CFG_PROXY_HOST="${CFG_PROXY_HOST:-}"
	CFG_ADMIN_UID="${CFG_ADMIN_UID:-}"
	CFG_ADMIN_EMAIL="${CFG_ADMIN_EMAIL:-}"
	CFG_LDAP_CERT_CN="${CFG_LDAP_CERT_CN:-}"
	CFG_LDAPS_HOST="${CFG_LDAPS_HOST:-}"
	CFG_CLIENT_ID="${CFG_CLIENT_ID:-}"
	CFG_CLIENT_SECRET="${CFG_CLIENT_SECRET:-}"
	CFG_LDAP_ADMIN_PASS="${CFG_LDAP_ADMIN_PASS:-}"
	CFG_JWT_SECRET="${CFG_JWT_SECRET:-}"
	CFG_ADMIN_PASS="${CFG_ADMIN_PASS:-}"
	CFG_SVC_PASS="${CFG_SVC_PASS:-}"
	CFG_PROXY_ADMIN_PASS="${CFG_PROXY_ADMIN_PASS:-}"
	CFG_CREATE_ALL_HTTP="${CFG_CREATE_ALL_HTTP:-0}"

	# ── One-time migration from .env / proxy.env (existing deployments) ──
	# Preserve the operator's existing secrets so the running deployment keeps
	# its LDAP directory, JWT, and OAuth client. After migration .env/proxy.env
	# are dead weight — setup.sh prints a reminder to delete them.
	local migrated=0
	if [[ -f .env ]]; then
		info "Migrating secrets from .env into $CONFIG_DIR/ ..."
		parse_kv_file .env
		CFG_BASE_DN="${LDAP_BASE_DN:-$CFG_BASE_DN}"
		CFG_DOMAIN="${LDAP_DOMAIN:-$CFG_DOMAIN}"
		CFG_ORG="${ORG_NAME:-$CFG_ORG}"
		CFG_SSO_HOST="${SSO_HOST:-$CFG_SSO_HOST}"
		CFG_PROXY_HOST="${PROXY_HOST:-$CFG_PROXY_HOST}"
		CFG_ADMIN_UID="${BOOTSTRAP_ADMIN_UID:-$CFG_ADMIN_UID}"
		CFG_ADMIN_EMAIL="${BOOTSTRAP_ADMIN_EMAIL:-$CFG_ADMIN_EMAIL}"
		CFG_LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:-$CFG_LDAP_ADMIN_PASS}"
		CFG_JWT_SECRET="${JWT_SECRET:-$CFG_JWT_SECRET}"
		CFG_ADMIN_PASS="${BOOTSTRAP_ADMIN_PASS:-$CFG_ADMIN_PASS}"
		CFG_SVC_PASS="${LDAP_SERVICE_PASS:-$CFG_SVC_PASS}"
		CFG_LDAP_CERT_CN="${LDAP_CERT_CN:-$CFG_LDAP_CERT_CN}"
		# .env has no legacy LDAPS_HOST key; this stays as set in setup.env/env.
		CFG_LDAPS_HOST="${CFG_LDAPS_HOST:-}"
		CFG_SMTP_HOST="${SMTP_HOST:-${CFG_SMTP_HOST:-}}"
		CFG_SMTP_PORT="${SMTP_PORT:-${CFG_SMTP_PORT:-}}"
		CFG_SMTP_USER="${SMTP_USER:-${CFG_SMTP_USER:-}}"
		CFG_SMTP_PASS="${SMTP_PASS:-${CFG_SMTP_PASS:-}}"
		CFG_SMTP_FROM="${SMTP_FROM:-${CFG_SMTP_FROM:-}}"
		migrated=1
	fi
	if [[ -f proxy.env ]]; then
		info "Migrating proxy config from proxy.env into $CONFIG_DIR/ ..."
		# proxy.env uses app_* keys; pull the OAuth client creds out directly.
		CFG_CLIENT_ID="$(grep -m1 '^app_oidc__clientId=' proxy.env 2>/dev/null | cut -d= -f2- || true)"
		CFG_CLIENT_SECRET="$(grep -m1 '^app_oidc__clientSecret=' proxy.env 2>/dev/null | cut -d= -f2- || true)"
		# LDAP_BIND_PASSWORD in proxy.env == the service account pass.
		local pbp; pbp="$(grep -m1 '^app_ldap__bindPassword=' proxy.env 2>/dev/null | cut -d= -f2- || true)"
		[[ -n "$pbp" ]] && CFG_SVC_PASS="$pbp"
		migrated=1
	fi

	# Derive everything from the domain — the one value operators enter. No
	# example.com defaults: a blank domain means first-run setup hasn't been
	# done yet. CFG_BASE_DN can still be set directly (setup.env or a migrated
	# .env) to override the derived DN or to read the domain back out of an
	# old-style DN-first setup.env; if not, it's built from CFG_DOMAIN.
	CFG_DOMAIN="${CFG_DOMAIN:-$([[ -n "$CFG_BASE_DN" ]] && domain_from_dn "$CFG_BASE_DN" || true)}"
	[[ -n "$CFG_DOMAIN" ]] \
		|| die "First run: 'cp setup.env.example setup.env', set CFG_DOMAIN to your domain (e.g. example.com), then re-run ./setup.sh"
	CFG_BASE_DN="${CFG_BASE_DN:-$(dn_from_domain "$CFG_DOMAIN")}"
	CFG_SSO_HOST="${CFG_SSO_HOST:-sso.$CFG_DOMAIN}"
	CFG_PROXY_HOST="${CFG_PROXY_HOST:-proxy.$CFG_DOMAIN}"
	CFG_SITE_NAME="${CFG_SITE_NAME:-local}"
	CFG_ORG="${CFG_ORG:-SSO Manager}"
	CFG_ADMIN_UID="${CFG_ADMIN_UID:-admin}"
	CFG_ADMIN_EMAIL="${CFG_ADMIN_EMAIL:-admin@$CFG_PROXY_HOST}"
	CFG_LDAP_CERT_CN="${CFG_LDAP_CERT_CN:-}"
	CFG_LDAPS_HOST="${CFG_LDAPS_HOST:-}"
	CFG_CLIENT_ID="${CFG_CLIENT_ID:-}"
	CFG_CLIENT_SECRET="${CFG_CLIENT_SECRET:-}"
	# Random secrets (generated fresh unless sourced/migrated above). These do
	# NOT belong in setup.env — they're written into ./config/*.js only.
	CFG_LDAP_ADMIN_PASS="${CFG_LDAP_ADMIN_PASS:-$(rand_hex 16)}"
	CFG_JWT_SECRET="${CFG_JWT_SECRET:-$(rand_hex 32)}"
	CFG_ADMIN_PASS="${CFG_ADMIN_PASS:-$(rand_hex 16)}"
	CFG_SVC_PASS="${CFG_SVC_PASS:-$(rand_hex 16)}"
	CFG_PROXY_ADMIN_PASS="${CFG_PROXY_ADMIN_PASS:-$(rand_hex 16)}"

	mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"
	write_sso_secrets
	write_proxy_secrets
	
	chmod 600 "$CONFIG_DIR/sso-secrets.js" "$CONFIG_DIR/proxy-secrets.js"

	if [[ "$migrated" == "1" ]]; then
		info "Migrated secrets into $CONFIG_DIR/ (existing LDAP dir / JWT / OAuth client preserved)."
		info "You may now delete .env and proxy.env — they are no longer used."
	else
		info "Generated $CONFIG_DIR/sso-secrets.js + proxy-secrets.js from ./setup.env (domain=$CFG_DOMAIN)."
		info "Edit $CONFIG_DIR/*.js to change secrets later; re-run ./setup.sh to rebuild."
	fi
}

ensure_config

# ── 3. backup_before_rebuild ──────────────────────────────────────────────────
# Snapshot ./config + LDAP (slapcat) + both Redis (BGSAVE + dump.rdb) before the
# rebuild. No-op on the very first run (nothing running, no config to lose yet).
backup_before_rebuild() {
	# If a command trips `set -e` and aborts the snapshot, name the offending
	# command instead of dying silently after "Snapshotting state to ..." (the
	# ERR trap fires for the same failures set -e would exit on, with the same
	# if/&&/|| exemptions, and is scoped to this function).
	trap 'warn "  snapshot aborted by command: $BASH_COMMAND"' ERR
	local any_running=0
	running sso-manager && any_running=1
	running proxy && any_running=1
	if [[ "$any_running" == "0" && ! -d "$CONFIG_DIR" ]]; then
		info "First run — nothing to back up yet."
		return 0
	fi

	# A timestamp suffix. `date` is fine here (setup.sh runs on the host).
	local ts; ts="$(date +%Y%m%d-%H%M%S)"
	local dir="$BACKUP_DIR/$ts"
	mkdir -p "$dir" && chmod 700 "$dir"
	info "Snapshotting state to $dir/ before rebuild..."

	# Config (the secrets source — the most important thing to back up).
	if [[ -d "$CONFIG_DIR" ]]; then
		if cp -a "$CONFIG_DIR" "$dir/config" 2>/dev/null; then
			info "  config -> config/"
		else
			warn "  could not copy $CONFIG_DIR/"
		fi
	fi

	# LDAP — slapcat the live directory while slapd is running. Read the base
	# DN from the host-side config first (works whether or not the running
	# container has /config mounted — e.g. a container from before the ./config
	# bind-mount was added), then fall back to reading it inside the container.
	# Use `docker exec <name>` (not `docker-compose exec`) so the snapshot works
	# no matter which compose project brought the container up — the unified
	# theta-suite stack (project "theta-suite") and the standalone submodule stack
	# (project "sso-manager-node") both name it "sso-manager". `docker-compose
	# exec` from the superproject otherwise exits 1 silently (wrong project) and
	# the snapshot silently no-ops.
	if running sso-manager; then
		info "  LDAP: snapshotting..."
		local basedn=""
		if [[ -f "$CONFIG_DIR/sso-secrets.js" ]] && command -v node >/dev/null 2>&1; then
			# `timeout 5` guards against a malformed secrets.js that blocks at
			# require() time — without it a bad config would stall the whole
			# rebuild at this line with no further output.
			basedn="$(timeout 5 node -e 'console.log((require("'"$PWD/$CONFIG_DIR"'/sso-secrets.js").stack||{}).ldapBaseDn||"")' 2>/dev/null || true)"
		fi
		if [[ -z "$basedn" ]]; then
			basedn="$(docker exec sso-manager node -e \
				'console.log((require("/config/sso-secrets.js").stack||{}).ldapBaseDn||"")' 2>/dev/null || true)"
		fi
		if [[ -n "$basedn" ]]; then
			if timeout 20 docker exec sso-manager slapcat -f /etc/openldap/slapd.conf \
					-b "$basedn" > "$dir/ldap.ldif" 2>/dev/null; then
				info "  LDAP -> ldap.ldif ($basedn)"
			else
				warn "  slapcat failed (LDAP not ready?) — LDAP not snapshotted"
			fi
		else
			warn "  could not read ldapBaseDn from sso-secrets.js — LDAP not snapshotted"
		fi
	else
		info "  LDAP: sso-manager not running — skipped"
	fi

	# Redis — snapshot each running service. Capture LASTSAVE *before* issuing
	# BGSAVE: a small dataset finishes in well under a second, so capturing it
	# afterward races the save and the poll never sees a fresh value (the bug
	# behind "BGSAVE did not finish in 30s"). BGSAVE is non-blocking but can
	# fork-fail when the host has vm.overcommit_memory=0; fall back to a
	# synchronous SAVE (blocks Redis briefly, but can't fork-fail — and we're
	# about to tear the containers down for a rebuild anyway). Then copy the RDB
	# from Redis's own `dir`/`dbfilename` (not a hardcoded /data/dump.rdb — the
	# standalone SSO stack keeps it at /app/dump.rdb) via `docker cp` by name, so
	# it works regardless of which compose project owns the container.
	local svc before ok rdir rfile rpath
	for svc in sso-manager proxy; do
		if ! running "$svc"; then
			info "  Redis ($svc): not running — skipped"
			continue
		fi
		info "  Redis ($svc): snapshotting..."
		before="$(docker exec "$svc" redis-cli LASTSAVE 2>/dev/null | tr -dc '0-9' || echo 0)"
		docker exec "$svc" redis-cli BGSAVE >/dev/null 2>&1 || true
		ok=0
		for i in $(seq 1 10); do
			if [[ "$(docker exec "$svc" redis-cli LASTSAVE 2>/dev/null | tr -dc '0-9' || echo 0)" -gt "$before" ]]; then
				ok=1; break
			fi
			sleep 1
		done
		if [[ "$ok" != "1" ]]; then
			# BGSAVE didn't advance LASTSAVE in time (fork failure / save already
			# in progress) — synchronous SAVE. Reply must be "OK".
			[[ "$(docker exec "$svc" redis-cli SAVE 2>/dev/null | tr -d '\r\n')" == "OK" ]] && ok=1
		fi
		# Redis writes dump.rdb to `dir`/`dbfilename`; ask it where that is so the
		# copy works across the unified (/data) and standalone (/app) layouts.
		rdir="$(docker exec "$svc" redis-cli CONFIG GET dir 2>/dev/null | sed -n '2p' | tr -d '\r\n' || true)"
		rfile="$(docker exec "$svc" redis-cli CONFIG GET dbfilename 2>/dev/null | sed -n '2p' | tr -d '\r\n' || true)"
		rpath="${rdir:+$rdir/}${rfile:-dump.rdb}"
		if [[ "$ok" == "1" ]] && docker cp "$svc:$rpath" "$dir/$svc.rdb" >/dev/null 2>&1; then
			info "  Redis ($svc) -> $svc.rdb"
		else
			warn "  $svc: snapshot failed — Redis not snapshotted"
		fi
	done

	# Retention: keep the newest BACKUP_KEEP (min 1). Use `[[ ]]` (not `(( ))`)
	# for the min-1 clamp: `(( keep < 1 ))` returns exit 1 when false, which is a
	# classic set -e landmine — `[[ ]]` is exempt as the left operand of `&&`.
	local keep="${BACKUP_KEEP:-5}"
	[[ "$keep" -lt 1 ]] && keep=1
	info "  pruning old backups (keep=$keep)..."
	local removed=0
	while read -r old; do
		[[ -n "$old" ]] || continue
		# Only prune real backup dirs — skip symlinks (a stray symlink could
		# point rm at an arbitrary tree) and non-dir entries.
		[[ -d "$BACKUP_DIR/$old" && ! -L "$BACKUP_DIR/$old" ]] || continue
		rm -rf "${BACKUP_DIR:?}/$old" || true
		removed=$((removed + 1))
	done < <(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r | tail -n +$((keep + 1)))
	[[ "$removed" -gt 0 ]] && info "  pruned $removed old backup(s) (keeping $keep)."
	info "  snapshot complete."
}
backup_before_rebuild

# ── 3b. Setup OpenBao (Vault) ────────────────────────────────────────────────
info "Starting openbao..."
"${COMPOSE[@]}" run --rm --user root openbao chown -R 100:1000 /vault/data
"${COMPOSE[@]}" up -d openbao
info "Waiting for openbao to be reachable..."
for i in $(seq 1 30); do
	if docker exec openbao bao status >/dev/null 2>&1 || [[ $? -eq 2 ]]; then
		info "openbao is reachable."; break
	fi
	if (( i == 30 )); then die "openbao did not become reachable in 60s. Check: ${COMPOSE[*]} logs openbao"; fi
	sleep 2
done

if ! docker exec openbao bao status -format=json 2>/dev/null | grep -q '"initialized": true'; then
    status_json=$(docker exec openbao bao status -format=json 2>/dev/null || true)
    if ! echo "$status_json" | grep -q '"initialized": true'; then
        info "Initializing openbao for the first time..."
        docker exec openbao bao operator init -key-shares=1 -key-threshold=1 -format=json > "$CONFIG_DIR/bao-init.json"
        chmod 600 "$CONFIG_DIR/bao-init.json"
        info "Openbao initialized. Keys saved to $CONFIG_DIR/bao-init.json"
    fi
fi

status_json=$(docker exec openbao bao status -format=json 2>/dev/null || true)
if echo "$status_json" | grep -q '"sealed": true'; then
	info "Unsealing openbao..."
	UNSEAL_KEY=$(grep -A1 '"unseal_keys_b64":' "$CONFIG_DIR/bao-init.json" | tail -n1 | cut -d'"' -f2)
	docker exec openbao bao operator unseal "$UNSEAL_KEY" >/dev/null
fi

export VAULT_TOKEN
VAULT_TOKEN=$(grep '"root_token":' "$CONFIG_DIR/bao-init.json" | cut -d'"' -f4)
env_upsert VAULT_TOKEN "$VAULT_TOKEN"

if ! docker exec -e BAO_TOKEN="$VAULT_TOKEN" openbao bao secrets list -format=json 2>/dev/null | grep -q '"secret/":'; then
    info "Enabling kv-v2 secrets engine at secret/..."
    docker exec -e BAO_TOKEN="$VAULT_TOKEN" openbao bao secrets enable -path=secret kv-v2 >/dev/null
fi

# ── 3c. OpenBao policies, token role, per-app tokens ─────────────────────────
# Each app gets a least-privilege scoped token (a policy over only its own
# secret/<app>/conf). sso additionally gets the `sso-broker` policy so it can
# mint per-user (user-<uid>) and per-app (app-<name>) tokens at runtime through
# the sso-broker token role. The root VAULT_TOKEN stays in .env for
# setup/maintenance ONLY and is never passed to a service container. Everything
# here is idempotent — re-running setup.sh keeps existing policies/tokens.

# Run a `bao` command inside the openbao container as root.
bao_run() { docker exec -e BAO_TOKEN="$VAULT_TOKEN" openbao bao "$@"; }

# Write an ACL policy from stdin HCL only if it does not already exist.
ensure_policy() {
	local name="$1"
	# Always (re)write: `bao policy write` is an idempotent overwrite, so this
	# applies policy edits on a re-run instead of stranding the old HCL
	# forever ("already exists — keeping" silently dropped upgrades — e.g.
	# the secret/metadata mount-root list grant added for the /vault fix).
	info "  writing policy ${name}..."
	docker exec -i -e BAO_TOKEN="$VAULT_TOKEN" openbao bao policy write "$name" - >/dev/null
}

# Read KEY= from ./.env (empty if absent) — reuse a previously minted token
# instead of minting a fresh one on every setup.sh run.
env_get() {
	local key="$1" file=./.env
	[[ -f "$file" ]] || return 0
	# `|| true` is load-bearing: under `set -euo pipefail`, a no-match `grep`
	# exits 1 and (pipefail) makes the whole pipeline return 1. Callers do
	# `existing="$(env_get ...)"` as a bare assignment — a non-zero return there
	# trips `set -e` and silently kills the whole script (this is exactly what
	# aborted a fresh install right after "Minting per-app OpenBao tokens": the
	# root VAULT_TOKEN env_upsert had already created .env, but the app-token
	# keys were absent, so the first env_get returned 1). "Key absent" is the
	# normal path here, so always return 0 with empty output.
	grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

# Mint an orphan, renewable token for `policy` and persist it to .env as `key`,
# OR reuse the token already in .env if it is still valid (re-mint on expiry).
ensure_token() {
	local key="$1" policy="$2" existing tok
	existing="$(env_get "$key")"
	if [[ -n "$existing" ]] && docker exec -e BAO_TOKEN="$existing" openbao bao token lookup >/dev/null 2>&1; then
		info "  ${key} already minted + valid — keeping."
		return 0
	fi
	info "  minting ${key} (policy=${policy})..."
	tok="$(bao_run token create -policy="$policy" -orphan=true -field=token)" \
		|| die "failed to mint ${key} (policy=${policy})"
	env_upsert "$key" "$tok"
}

# Seed secret/<vault_path> from a /config/*.js module on first run only
# (skipped if the path already exists). Fail-soft: a seed failure leaves the
# app's file-mounted config as the fallback — boot is not blocked.
seed_app_conf() {
	local vault_path="$1" mod="$2"
	if bao_run kv get "secret/${vault_path}" >/dev/null 2>&1; then
		info "  secret/${vault_path} already seeded — keeping."
		return 0
	fi
	info "Seeding secret/${vault_path} from ${mod}..."
	docker exec sso-manager node -e "console.log(JSON.stringify(require('${mod}')))" 2>/dev/null \
		| docker exec -i -e BAO_TOKEN="$VAULT_TOKEN" openbao bao kv put "secret/${vault_path}" - >/dev/null \
		|| warn "  could not seed secret/${vault_path} (continuing — app will use its file fallback)"
}

info "Configuring OpenBao policies..."
# sso-broker — sso's authority to read/write its own conf, mint per-user and
# per-app tokens (auth/token/create/sso-broker), and create the matching
# user-<uid> / app-<name> / sso-admin policies. secret/plugins/* holds per-instance
# plugin secrets managed by the SSO plugin system (configurable plugin copies,
# loaded/unloaded at runtime — see sso-manager-node docs/plugins.md).
ensure_policy sso-broker <<'HCL'
path "secret/data/sso-manager/conf" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/metadata/sso-manager/conf" { capabilities = ["list", "read", "delete"] }
path "secret/data/proxy/conf" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/metadata/proxy/conf" { capabilities = ["list", "read", "delete"] }
path "secret/data/users/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/metadata/users/*" { capabilities = ["list", "read", "delete"] }
path "secret/data/apps/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/metadata/apps/*" { capabilities = ["list", "read", "delete"] }
path "secret/data/plugins/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/metadata/plugins/*" { capabilities = ["list", "read", "delete"] }
path "auth/token/create/sso-broker" { capabilities = ["update"] }
path "sys/policies/acl/user-*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policies/acl/app-*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policies/acl/sso-admin" { capabilities = ["create", "read", "update", "delete", "list"] }
HCL
# sso-admin — admin users in the vault UI: read/write/list everything under secret/.
# The bare `secret/metadata` grant lets an admin LIST the KV mount root (the
# top-level dirs); `secret/metadata/*` covers nested paths but not the root
# itself, so without it the /vault secrets list 403s.
ensure_policy sso-admin <<'HCL'
path "secret/data/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/metadata" { capabilities = ["list", "read", "delete"] }
path "secret/metadata/" { capabilities = ["list", "read", "delete"] }
path "secret/metadata/*" { capabilities = ["list", "read", "delete"] }
HCL
# proxy / jump-host — read only their own boot conf.
ensure_policy proxy <<'HCL'
path "secret/data/proxy/conf" { capabilities = ["read"] }
path "secret/data/proxy/dns-providers/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/metadata/proxy/dns-providers/*" { capabilities = ["list", "read", "delete"] }
path "secret/metadata/proxy/conf" { capabilities = ["read", "list"] }
HCL
ensure_policy jump-host <<'HCL'
path "secret/data/jump-host/conf" { capabilities = ["read"] }
path "secret/metadata/jump-host/conf" { capabilities = ["read", "list"] }
HCL

# sso-broker token role: lets sso mint user-*/app-*/sso-admin tokens. Orphan,
# renewable, 24h period. Wildcards need allowed_policies_glob — allowed_policies
# is exact-match only.
info "Configuring sso-broker token role..."
if ! bao_run read auth/token/roles/sso-broker >/dev/null 2>&1; then
	docker exec -i -e BAO_TOKEN="$VAULT_TOKEN" openbao bao write auth/token/roles/sso-broker - <<'JSON' >/dev/null
{"allowed_policies":["sso-admin"],"allowed_policies_glob":["user-*","app-*"],"orphan":true,"renewable":true,"token_period":"24h"}
JSON
else
	info "  token role sso-broker already exists — keeping."
fi

info "Minting per-app OpenBao tokens (stored in .env, passed to containers as VAULT_TOKEN)..."
ensure_token SSO_VAULT_TOKEN sso-broker
ensure_token PROXY_VAULT_TOKEN proxy
ensure_token JUMP_VAULT_TOKEN jump-host

info "OpenBao secrets configured:"
info "  policies:   sso-broker, sso-admin, proxy, jump-host (+ per-user/app created lazily by sso)"
info "  token role: sso-broker (mints user-*/app-*/sso-admin tokens, 24h period)"
info "  app tokens: SSO_VAULT_TOKEN, PROXY_VAULT_TOKEN, JUMP_VAULT_TOKEN in .env"

# ── 4. Start SSO Manager, wait for health ─────────────────────────────────────
# SSO_GIT_COMMIT: sso-manager-node is a git submodule here, so its .git is a
# pointer file (not a real repo) -- the image can't resolve its own commit
# hash from inside the Docker build context. Resolve it on the host (where
# the submodule DOES resolve correctly) and pass it in as a build arg; see
# docker-compose.yml and sso-manager-node's Dockerfile.openldap.
SSO_GIT_COMMIT="$(git -C sso-manager-node rev-parse --short HEAD 2>/dev/null || echo unknown)"
export SSO_GIT_COMMIT
env_upsert SSO_GIT_COMMIT "$SSO_GIT_COMMIT"
info "Building + starting sso-manager (first run builds the image; this takes a while)..."
"${COMPOSE[@]}" up -d --build sso-manager

info "Waiting for sso-manager to be healthy..."
for i in $(seq 1 60); do
	status=$("${COMPOSE[@]}" ps -o json sso-manager 2>/dev/null \
	         | grep -o '"Health":"healthy"' || true)
	if [[ -n "$status" ]]; then info "sso-manager is healthy."; break; fi
	if docker exec sso-manager wget -q -O- http://localhost:3001/health >/dev/null 2>&1; then
		info "sso-manager is healthy (probed /health)."; break
	fi
	if (( i == 60 )); then die "sso-manager did not become healthy in 60s. Check: ${COMPOSE[*]} logs sso-manager"; fi
	sleep 2
done

info "Seeding app configs into OpenBao (idempotent)..."
# sso-manager/conf holds the operator-set LDAP/SMTP/jwtSecret values — sso has
# no bootstrap-generated creds, so the file is the complete source of truth.
seed_app_conf sso-manager/conf /config/sso-secrets.js
# proxy/conf is seeded from the operator file (placeholder OAuth creds); the
# bootstrap (step 5) then writes the real generated OAuth client creds into
# OpenBao over this. proxy boots at step 6, after bootstrap, so it sees the
# real values.
seed_app_conf proxy/conf /config/proxy-secrets.js

# Read the summary values (hosts, admin, base DN) back from ./config via the
# running container's node — works whether ./config was generated or pre-existing.
read_config_kv() {
	"${COMPOSE[@]}" exec -T sso-manager node -e '
		const c = require("/config/sso-secrets.js");
		let p = {};
		try { p = require("/config/proxy-secrets.js"); } catch (_) {}
		const o = {
			SSO_HOST: (c.stack && c.stack.ssoHost) || "",
			PROXY_HOST: (c.stack && c.stack.proxyHost) || "",
			LDAP_BASE_DN: (c.stack && c.stack.ldapBaseDn) || "",
			ORG_NAME: c.name || "",
			ADMIN_UID: (c.bootstrap && c.bootstrap.adminUid) || "",
		};
		for (const k in o) console.log(k + "=" + (o[k] == null ? "" : o[k]));
	' 2>/dev/null
}
CFG_OUT="$(read_config_kv || true)"
cfgval() { echo "$CFG_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
SSO_HOST="$(cfgval SSO_HOST)"
PROXY_HOST="$(cfgval PROXY_HOST)"
ADMIN_UID="$(cfgval ADMIN_UID)"

info "Stack config:"
info "  SSO host:      https://${SSO_HOST}"
info "  Proxy host:    https://${PROXY_HOST}"
info "  Admin uid:     ${ADMIN_UID}"

# ── 5. Run the bootstrap (writes CLIENT_ID/CLIENT_SECRET/ALREADY_CONFIGURED) ──
# The bootstrap reads its inputs from /config/*.js (not env) and writes the
# generated OAuth client creds back into /config/proxy-secrets.js AND into
# OpenBao (secret/proxy/conf, secret/jump-host/conf) so the proxy + jump host
# load them from OpenBao at boot. The root VAULT_TOKEN is passed on this one
# exec so bootstrap can write those paths; it is never handed to a service
# container.
info "Running bootstrap (creates/updates the LDAP service account, first admin, OAuth client)..."
# Host facts for the directory seed — collected HERE (on the host; inside the
# container hostname/uname describe the container, not the machine). Same
# collection as ldap-client/index.sh so stack hosts and ldap-client-joined
# hosts carry identical metadata. All best-effort: a missing tool just leaves
# the field blank.
STACK_HOST_NAME="$(hostname 2>/dev/null || true)"
STACK_HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
_iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
STACK_HOST_MAC=""
[[ -n "$_iface" ]] && STACK_HOST_MAC="$(cat "/sys/class/net/$_iface/address" 2>/dev/null || true)"
STACK_HOST_OS="$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}") || true)"
STACK_HOST_KERNEL="$(uname -r 2>/dev/null || true)"
BOOTSTRAP_OUT=$("${COMPOSE[@]}" exec -T \
	-e STACK_HOST_NAME="$STACK_HOST_NAME" \
	-e STACK_HOST_IP="$STACK_HOST_IP" \
	-e STACK_HOST_MAC="$STACK_HOST_MAC" \
	-e STACK_HOST_OS="$STACK_HOST_OS" \
	-e STACK_HOST_KERNEL="$STACK_HOST_KERNEL" \
	-e CFG_JUMP_HOST="${CFG_JUMP_HOST:-}" \
	-e VAULT_ADDR=http://openbao:8200 \
	-e VAULT_TOKEN="$VAULT_TOKEN" \
	sso-manager node /bootstrap/bootstrap.js) \
	|| die "bootstrap failed:\n${BOOTSTRAP_OUT}"

getval() { echo "$BOOTSTRAP_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
CLIENT_ID=$(getval CLIENT_ID)
ALREADY_CONFIGURED=$(getval ALREADY_CONFIGURED)
[[ -n "$CLIENT_ID" ]] || die "bootstrap did not return CLIENT_ID:\n${BOOTSTRAP_OUT}"

if [[ "$ALREADY_CONFIGURED" == "1" ]]; then
	info "Stack was already configured — OAuth client creds in proxy-secrets.js are current."
else
	info "OAuth client registered + creds written into $CONFIG_DIR/proxy-secrets.js."
fi

# ── 6. Start the proxy, wait for health ───────────────────────────────────────
# PROXY_GIT_COMMIT: same reasoning as SSO_GIT_COMMIT above.
PROXY_GIT_COMMIT="$(git -C proxy rev-parse --short HEAD 2>/dev/null || echo unknown)"
export PROXY_GIT_COMMIT
env_upsert PROXY_GIT_COMMIT "$PROXY_GIT_COMMIT"
info "Building + starting proxy (first run builds the image; this takes a while)..."
"${COMPOSE[@]}" up -d --build proxy

info "Waiting for proxy to be healthy..."
for i in $(seq 1 60); do
	if docker exec proxy curl -fsS http://localhost:3000/health >/dev/null 2>&1; then
		info "proxy is healthy."; break
	fi
	if (( i == 60 )); then die "proxy did not become healthy in 60s. Check: ${COMPOSE[*]} logs proxy"; fi
	sleep 2
done

# ── 7. Register the SSO + proxy UIs as Host records in the proxy ──────────────
# The proxy routes EVERY hostname it serves — including its own management UI
# and the SSO's UI — off a Host record (ops/nginx_conf/proxy.conf has no
# default/self route; targetinfo.lua does a lookup for every request, full
# stop). Nothing else creates these two, so without this step https://<SSO_HOST>
# and https://<PROXY_HOST> 404 on first run. sso_enabled is left false on both:
# each app gates its own login already, and SSO-gating the SSO's own login page
# would be circular. Idempotent — skips a host that already exists.
info "Registering ${SSO_HOST} and ${PROXY_HOST} with the proxy..."
HOSTS_OUT=$("${COMPOSE[@]}" exec -T proxy node <<NODEEOF
const {Host} = require('/app/models').models;

async function ensureHost(host, ip, targetPort) {
	try {
		await Host.get(host);
		console.log('SKIP ' + host + ' (already exists)');
	} catch (error) {
		if (error.name !== 'EntryNotFound') throw error;
		await Host.create({
			host: host,
			ip: ip,
			targetPort: targetPort,
			forcessl: $( [[ "$CFG_CREATE_ALL_HTTP" == "1" ]] && echo false || echo true ),
			targetssl: false,
			sso_enabled: false,
			created_by: 'setup.sh',
		});
		console.log('CREATED ' + host + ' -> ' + ip + ':' + targetPort);
	}
}

(async () => {
	try {
		await ensureHost($(js_str "$SSO_HOST"), 'sso-manager', 3001);
		await ensureHost($(js_str "$PROXY_HOST"), '127.0.0.1', 3000);
		process.exit(0);
	} catch (error) {
		console.error('ERROR', error.message);
		process.exit(1);
	}
})();
NODEEOF
) || die "Registering hosts with the proxy failed:\n${HOSTS_OUT}"
echo "$HOSTS_OUT" | sed 's/^/[setup] /'

# ── 7b. Build + start the SSH jump host ──────────────────────────────────────
# The jump host is a core component (no longer optional). The bootstrap (step 5)
# already wrote ./config/jump-secrets.js (minted API token + LDAP admin bind) and
# mirrored it into OpenBao. Build/start the service, wait for its web /health,
# and register its web UI hostname as a proxy Host so https://<JUMP_HOST> routes.
JUMP_HOST="${CFG_JUMP_HOST:-jump.${SSO_HOST#sso.}}"
JUMP_GIT_COMMIT="$(git -C jump-host rev-parse --short HEAD 2>/dev/null || echo unknown)"
export JUMP_GIT_COMMIT
env_upsert JUMP_GIT_COMMIT "$JUMP_GIT_COMMIT"
# Seed jump-host/conf from the file bootstrap just wrote (it mints the API
# token + OAuth client into /config/jump-secrets.js at step 5). bootstrap also
# writes this to OpenBao directly, so this is a fallback for when bootstrap's
# jump provisioning warned-but-continued.
seed_app_conf jump-host/conf /config/jump-secrets.js
info "Building + starting jump-host..."
"${COMPOSE[@]}" up -d --build jump-host

info "Waiting for jump-host to be healthy..."
for i in $(seq 1 60); do
	if docker exec jump-host node -e "require('http').get('http://localhost:3002/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" >/dev/null 2>&1; then
		info "jump-host is healthy."; break
	fi
	if (( i == 60 )); then warn "jump-host did not become healthy in 120s. Check: ${COMPOSE[*]} logs jump-host"; break; fi
	sleep 2
done

info "Registering ${JUMP_HOST} (jump-host web UI) with the proxy..."
JUMP_HOSTS_OUT=$("${COMPOSE[@]}" exec -T proxy node <<NODEEOF || true
const {Host} = require('/app/models').models;
(async () => {
	try {
		try { await Host.get($(js_str "$JUMP_HOST")); console.log('SKIP ${JUMP_HOST} (already exists)'); }
		catch (e) {
			if (e.name !== 'EntryNotFound') throw e;
			await Host.create({ host: $(js_str "$JUMP_HOST"), ip: 'jump-host', targetPort: 3002, forcessl: $( [[ "$CFG_CREATE_ALL_HTTP" == "1" ]] && echo false || echo true ), targetssl: false, sso_enabled: false, created_by: 'setup.sh' });
			console.log('CREATED ${JUMP_HOST} -> jump-host:3002');
		}
		process.exit(0);
	} catch (error) { console.error('ERROR', error.message); process.exit(1); }
})();
NODEEOF
)
echo "$JUMP_HOSTS_OUT" | sed 's/^/[setup] /'

# ── 7c. Install theta-agent on the host ──────────────────────────────────────
# Controlled by CFG_THETA_AGENT_ENABLE (default: 1 = enabled)
CFG_THETA_AGENT_ENABLE="${CFG_THETA_AGENT_ENABLE:-1}"
if [[ "$CFG_THETA_AGENT_ENABLE" == "1" ]]; then
	info "Setting up theta-agent on the host..."
	(
		cd theta-agent || exit 0
		if ! command -v go >/dev/null 2>&1; then
			warn "Go is not installed. Skipping theta-agent installation."
		else
			info "  Building theta-agent..."
			go build -o theta-agent main.go websocket.go config.go || warn "  Failed to build theta-agent."
			if [[ -x "theta-agent" ]]; then
				sudo mkdir -p /etc/theta
				if [[ ! -f /etc/theta/agent.yml ]]; then
					sudo cp agent.yml.example /etc/theta/agent.yml
					AGENT_TOKEN="$(rand_hex 16)"
					sudo sed -i "s/REPLACE_WITH_AGENT_TOKEN/$AGENT_TOKEN/" /etc/theta/agent.yml
					# We want to connect to either https or http depending on CFG_CREATE_ALL_HTTP
					if [[ "$CFG_CREATE_ALL_HTTP" == "1" ]]; then
						sudo sed -i "s|https://sso.example.com|http://${SSO_HOST}|" /etc/theta/agent.yml
					else
						sudo sed -i "s|https://sso.example.com|https://${SSO_HOST}|" /etc/theta/agent.yml
					fi
				fi
				sudo cp theta-agent /usr/local/bin/theta-agent
				sudo chmod +x /usr/local/bin/theta-agent

				sudo bash -c "cat <<'EOF' > /etc/systemd/system/theta-agent.service
[Unit]
Description=Theta Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/theta-agent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
				sudo systemctl daemon-reload
				sudo systemctl enable --now theta-agent.service
				info "  theta-agent installed and started."
			fi
		fi
	)
else
	info "theta-agent installation skipped (CFG_THETA_AGENT_ENABLE=0)."
fi
# ── 7d. Configure theta-agent integration with this host ─────────────────────
# Non-interactive configuration driven by setup.env variables:
#   CFG_THETA_AGENT_ENABLE (default: 1) - Install/configure theta-agent
#   CFG_THETA_AGENT_LDAP_AUTH (default: 1) - Configure LDAP authentication via ldap-client
#   CFG_THETA_AGENT_FULL_CONTROL (default: 1) - Enable all agent capabilities
# Only runs if theta-agent was installed (section 7c) or already exists.
if [[ "$CFG_THETA_AGENT_ENABLE" == "1" ]] && [[ -x /usr/local/bin/theta-agent ]]; then
	info "Configuring theta-agent integration with this host..."

	# Default to enabled unless explicitly disabled
	CFG_THETA_AGENT_LDAP_AUTH="${CFG_THETA_AGENT_LDAP_AUTH:-1}"
	CFG_THETA_AGENT_FULL_CONTROL="${CFG_THETA_AGENT_FULL_CONTROL:-1}"

	if [[ "$CFG_THETA_AGENT_LDAP_AUTH" == "1" ]]; then
		info "  Configuring LDAP authentication for this host..."
		(
			cd ldap-client || exit 0
			if [[ -x "index.sh" ]]; then
				bash index.sh --non-interactive 2>/dev/null || warn "  ldap-client enrollment failed (continuing)..."
			fi
		)
	else
		info "  LDAP authentication configuration skipped (CFG_THETA_AGENT_LDAP_AUTH=0)."
	fi

	if [[ "$CFG_THETA_AGENT_FULL_CONTROL" == "1" ]]; then
		info "  Configuring theta-agent with full host control capabilities..."
		if [[ -f /etc/theta/agent.yml ]]; then
			sudo sed -i 's/arbitrary_bash: false/arbitrary_bash: true/' /etc/theta/agent.yml
			sudo sed -i 's/service_control: .*/service_control: true/' /etc/theta/agent.yml
			sudo sed -i 's/reboot: false/reboot: true/' /etc/theta/agent.yml
			sudo sed -i 's/configure_ldap: false/configure_ldap: true/' /etc/theta/agent.yml
			info "  theta-agent full control enabled. Restarting service..."
			sudo systemctl restart theta-agent.service
		else
			warn "  /etc/theta/agent.yml not found. Full control not configured."
		fi
	else
		info "  theta-agent running with limited capabilities (CFG_THETA_AGENT_FULL_CONTROL=0)."
	fi
else
	info "  theta-agent configuration skipped (agent not installed or CFG_THETA_AGENT_ENABLE=0)."
fi

# ── 8. Summary ───────────────────────────────────────────────────────────────
echo
printf '\033[1;34m[setup]\033[0m \033[1;32mDone. Your SSO + proxy stack is up.\033[0m\n'
echo
echo "  SSO Manager UI:    https://${SSO_HOST}   (fronted by the proxy under TLS)"
echo "                      first-run fallback: http://127.0.0.1:${SSO_PORT:-3001}"
echo "  Proxy mgmt UI:      https://${PROXY_HOST}"
echo "                      first-run fallback: http://127.0.0.1:${MGMT_PORT:-3000}"
echo "  Jump host (SSH):    ssh -p ${JUMP_SSH_PORT:-2222} <uid>@${JUMP_HOST:-jump.${SSO_HOST#sso.}}   (TUI picker)"
echo "                      ssh -p ${JUMP_SSH_PORT:-2222} <uid>_-_<host>@${JUMP_HOST:-jump.${SSO_HOST#sso.}}"
echo "  Jump host (web):    https://${JUMP_HOST:-jump.${SSO_HOST#sso.}}   (audit + metrics)"
echo
echo "  First admin login credentials are in ./config/sso-secrets.js:"
echo "    user: ${ADMIN_UID}"
echo "    pass: ${CFG_ADMIN_PASS:-<see ./config/sso-secrets.js>}"
echo
echo "  Proxy local admin (anti-lockout fallback if the SSO is unreachable):"
echo "    user: proxyadmin2"
echo "    pass: auth.localAdminPass in ./config/proxy-secrets.js"
echo "    (only shown when the account is first created; edit ./config/proxy-secrets.js"
echo "    or use the proxy UI to change it afterward)"
echo
echo "  Secrets live in ./config/ (sso-secrets.js + proxy-secrets.js). Back them"
echo "  up off-host — ./setup.sh snapshots to ./backups/ before each rebuild."
echo
echo "  Next: add DNS records (or /etc/hosts) pointing ${SSO_HOST} and ${PROXY_HOST}"
echo "        at this host, then open https://${SSO_HOST} and log in as the admin."
echo "        The proxy auto-issues Let's Encrypt certs if port 80 is reachable;"
echo "        otherwise it serves a self-signed fallback on the LAN."
echo
echo "  Re-run ./setup.sh any time to converge the stack to ./config/ (idempotent)."