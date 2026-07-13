#!/usr/bin/env bash
#
# theta-env setup — one-command bring-up of the unified SSO Manager + Proxy stack.
#
#   git clone --recursive <theta-env> && cd theta-env
#   ./setup.sh            # generates ./config/ the first time — edit it, re-run
#   ./setup.sh            # builds + bootstraps + starts the stack
#
# Idempotent: safe to re-run. It manages config in a bind-mounted ./config/
# directory (sso-secrets.js + proxy-secrets.js — NO .env / proxy.env), snapshots
# state before rebuild, (re)starts the SSO Manager, runs the bootstrap (which
# converges the LDAP service account / first admin / OAuth client to the ./config
# values and writes the generated OAuth client creds into proxy-secrets.js),
# then starts the proxy.
#
# What it does, in order:
#   1. Update the git submodules to the latest of their tracked remote branch
#      (so each run builds the newest sso-manager-node + proxy). Skip with
#      SKIP_SUBMODULE_UPDATE=1.
#   2. ensure_config: create ./config/sso-secrets.js + proxy-secrets.js if
#      missing. On a fresh clone they're generated with random secrets and you
#      must edit them + re-run. On an existing deployment with .env/proxy.env,
#      the secrets are migrated (preserved) into ./config. If ./config already
#      exists it is left untouched (the operator owns it).
#   3. backup_before_rebuild: snapshot ./config + LDAP (slapcat) + both Redis
#      (BGSAVE + dump.rdb) to ./backups/<ts>/ before the rebuild. No-op on the
#      very first run. Keeps the last BACKUP_KEEP (default 5).
#   4. docker compose up -d --build sso-manager; wait for /health.
#   5. docker compose exec sso-manager node /bootstrap/bootstrap.js
#      -> creates/updates the LDAP service account, first admin, OAuth client;
#         writes the OAuth client creds into ./config/proxy-secrets.js; prints
#         CLIENT_ID / CLIENT_SECRET / ALREADY_CONFIGURED on stdout.
#   6. docker compose up -d --build proxy; wait for /health.
#   7. Print the first-admin login + the public URLs.
#
# Requires: git, docker + docker compose (v1 standalone or v2 plugin).

set -euo pipefail

cd "$(dirname "$0")"

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

# ── 1. Update submodules to latest, verify build contexts ─────────────────────
if [[ "${SKIP_SUBMODULE_UPDATE:-0}" != "1" ]]; then
	if ! command -v git >/dev/null 2>&1; then
		die "git not found. Install git, or set SKIP_SUBMODULE_UPDATE=1 to build the pinned submodule commits."
	fi
	info "Updating submodules to latest (sso-manager-node, proxy)..."
	if ! git submodule update --init --remote --recursive 2>&1; then
		warn "git submodule update failed (offline?) — continuing with the currently checked-out code."
	fi
else
	info "Skipping submodule update (SKIP_SUBMODULE_UPDATE=1)."
fi

[[ -f sso-manager-node/Dockerfile.openldap ]] \
	|| die "sso-manager-node/Dockerfile.openldap missing. Run: git submodule update --init --recursive"
[[ -f proxy/Dockerfile ]] \
	|| die "proxy/Dockerfile missing. Run: git submodule update --init --recursive"

# ── 2. ensure_config ──────────────────────────────────────────────────────────
# Derive a DNS domain from a base DN (dc=foo,dc=bar -> foo.bar).
domain_from_dn() {
	echo "$1" | sed 's/^dc=//; s/,dc=/./g'
}

# Write ./config/sso-secrets.js from the CFG_* shell vars.
write_sso_secrets() {
	local dn="$CFG_BASE_DN" domain="$CFG_DOMAIN"
	[[ -n "$domain" ]] || domain="$(domain_from_dn "$dn")"
	cat > "$CONFIG_DIR/sso-secrets.js" <<SSOEOF
'use strict';
// Generated by setup.sh. Edit freely; re-run ./setup.sh to apply.
// The SSO app reads this via @simpleworkjs/conf (symlinked to conf/secrets.js).
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

	// ── Orchestrator-only (ignored by the app) ───────────────────────────────
	stack: {
		ldapBaseDn: $(js_str "$dn"),
		ldapDomain: $(js_str "$domain"),
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
// Generated by setup.sh. The proxy reads this via @simpleworkjs/conf (symlinked
// to conf/secrets.js). clientId/clientSecret are filled in by the bootstrap
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
	},
	stack: {
		ssoHost: $(js_str "$CFG_SSO_HOST"),
		proxyHost: $(js_str "$CFG_PROXY_HOST"),
	},
};
PROXYEOF
}

ensure_config() {
	if [[ -f "$CONFIG_DIR/sso-secrets.js" ]]; then
		info "Using existing $CONFIG_DIR/sso-secrets.js (operator-owned — left untouched)."
		return 0
	fi

	# Defaults for a fresh generation. Overridden below by .env/proxy.env if the
	# operator is migrating from the old .env-based setup.
	CFG_BASE_DN="${CFG_BASE_DN:-dc=example,dc=com}"
	CFG_DOMAIN="${CFG_DOMAIN:-}"
	CFG_ORG="${CFG_ORG:-SSO Manager}"
	CFG_SSO_HOST="${CFG_SSO_HOST:-sso.example.com}"
	CFG_PROXY_HOST="${CFG_PROXY_HOST:-proxy.example.com}"
	CFG_ADMIN_UID="${CFG_ADMIN_UID:-admin}"
	CFG_ADMIN_EMAIL="${CFG_ADMIN_EMAIL:-}"
	CFG_LDAP_CERT_CN="${CFG_LDAP_CERT_CN:-}"
	CFG_CLIENT_ID="${CFG_CLIENT_ID:-}"
	CFG_CLIENT_SECRET="${CFG_CLIENT_SECRET:-}"
	# Random secrets (generated fresh unless migrated from .env below).
	CFG_LDAP_ADMIN_PASS="${CFG_LDAP_ADMIN_PASS:-$(rand_hex 16)}"
	CFG_JWT_SECRET="${CFG_JWT_SECRET:-$(rand_hex 32)}"
	CFG_ADMIN_PASS="${CFG_ADMIN_PASS:-$(rand_hex 16)}"
	CFG_SVC_PASS="${CFG_SVC_PASS:-$(rand_hex 16)}"

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
	[[ -n "$CFG_ADMIN_EMAIL" ]] || CFG_ADMIN_EMAIL="admin@${CFG_PROXY_HOST}"

	mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"
	write_sso_secrets
	write_proxy_secrets
	chmod 600 "$CONFIG_DIR/sso-secrets.js" "$CONFIG_DIR/proxy-secrets.js"

	if [[ "$migrated" == "1" ]]; then
		info "Migrated secrets into $CONFIG_DIR/ (existing LDAP dir / JWT / OAuth client preserved)."
		info "You may now delete .env and proxy.env — they are no longer used."
	else
		# Fresh generation with placeholder hostnames — the operator must edit.
		info "Generated $CONFIG_DIR/sso-secrets.js + proxy-secrets.js with random secrets."
		warn "EDIT $CONFIG_DIR/sso-secrets.js (set stack.ssoHost, stack.proxyHost, stack.ldapBaseDn,"
		warn "  bootstrap.adminUid/adminPass to your values), then re-run ./setup.sh."
		info "Re-run ./setup.sh after editing. (LDAP admin pass + JWT were generated for you —"
		info "change them in the file if you like, or leave them.)"
		exit 0
	fi
}

ensure_config

# ── 3. backup_before_rebuild ──────────────────────────────────────────────────
# Snapshot ./config + LDAP (slapcat) + both Redis (BGSAVE + dump.rdb) before the
# rebuild. No-op on the very first run (nothing running, no config to lose yet).
backup_before_rebuild() {
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
		cp -a "$CONFIG_DIR" "$dir/config" 2>/dev/null \
			|| warn "  could not copy $CONFIG_DIR/"
	fi

	# LDAP — slapcat the live directory while slapd is running. Read the base
	# DN from the host-side config first (works whether or not the running
	# container has /config mounted — e.g. a container from before the ./config
	# bind-mount was added), then fall back to reading it inside the container.
	if running sso-manager; then
		local basedn=""
		if [[ -f "$CONFIG_DIR/sso-secrets.js" ]] && command -v node >/dev/null 2>&1; then
			basedn="$(node -e 'console.log((require("'"$PWD/$CONFIG_DIR"'/sso-secrets.js").stack||{}).ldapBaseDn||"")' 2>/dev/null || true)"
		fi
		if [[ -z "$basedn" ]]; then
			basedn="$("${COMPOSE[@]}" exec -T sso-manager node -e \
				'console.log((require("/config/sso-secrets.js").stack||{}).ldapBaseDn||"")' 2>/dev/null || true)"
		fi
		if [[ -n "$basedn" ]]; then
			if "${COMPOSE[@]}" exec -T sso-manager slapcat -f /etc/openldap/slapd.conf \
					-b "$basedn" > "$dir/ldap.ldif" 2>/dev/null; then
				info "  LDAP -> ldap.ldif ($basedn)"
			else
				warn "  slapcat failed (LDAP not ready?) — LDAP not snapshotted"
			fi
		else
			warn "  could not read ldapBaseDn from sso-secrets.js — LDAP not snapshotted"
		fi
	fi

	# Redis — snapshot each running service. Capture LASTSAVE *before* issuing
	# BGSAVE: a small dataset finishes in well under a second, so capturing it
	# afterward races the save and the poll never sees a fresh value (the bug
	# behind "BGSAVE did not finish in 30s"). BGSAVE is non-blocking but can
	# fork-fail when the host has vm.overcommit_memory=0; fall back to a
	# synchronous SAVE (blocks Redis briefly, but can't fork-fail — and we're
	# about to tear the containers down for a rebuild anyway). Then copy the RDB.
	local svc before ok
	for svc in sso-manager proxy; do
		running "$svc" || continue
		before="$(docker exec "$svc" redis-cli LASTSAVE 2>/dev/null | tr -dc '0-9' || echo 0)"
		docker exec "$svc" redis-cli BGSAVE >/dev/null 2>&1 || true
		ok=0
		for i in $(seq 1 10); do
			if [[ "$(docker exec "$svc" redis-cli LASTSAVE 2>/dev/null | tr -dc '0-9')" -gt "$before" ]]; then
				ok=1; break
			fi
			sleep 1
		done
		if [[ "$ok" != "1" ]]; then
			# BGSAVE didn't advance LASTSAVE in time (fork failure / save already
			# in progress) — synchronous SAVE. Reply must be "OK".
			[[ "$(docker exec "$svc" redis-cli SAVE 2>/dev/null | tr -d '\r\n')" == "OK" ]] && ok=1
		fi
		if [[ "$ok" == "1" ]] && "${COMPOSE[@]}" cp "$svc:/data/dump.rdb" "$dir/$svc.rdb" >/dev/null 2>&1; then
			info "  Redis ($svc) -> $svc.rdb"
		else
			warn "  $svc: snapshot failed — Redis not snapshotted"
		fi
	done

	# Retention: keep the newest BACKUP_KEEP (min 1).
	local keep="$BACKUP_KEEP"; (( keep < 1 )) && keep=1
	local removed=0
	while read -r old; do
		[[ -n "$old" ]] || continue
		rm -rf "$BACKUP_DIR/$old"
		removed=$((removed + 1))
	done < <(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r | tail -n +$((keep + 1)))
	[[ "$removed" -gt 0 ]] && info "  pruned $removed old backup(s) (keeping $keep)."
}
backup_before_rebuild

# ── 4. Start SSO Manager, wait for health ─────────────────────────────────────
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

# Read the summary values (hosts, admin, base DN) back from ./config via the
# running container's node — works whether ./config was generated or pre-existing.
read_config_kv() {
	"${COMPOSE[@]}" exec -T sso-manager node -e '
		const c = require("/config/sso-secrets.js");
		const o = {
			SSO_HOST: (c.stack && c.stack.ssoHost) || "",
			PROXY_HOST: (c.stack && c.stack.proxyHost) || "",
			LDAP_BASE_DN: (c.stack && c.stack.ldapBaseDn) || "",
			ORG_NAME: c.name || "",
			ADMIN_UID: (c.bootstrap && c.bootstrap.adminUid) || "",
			ADMIN_PASS: (c.bootstrap && c.bootstrap.adminPass) || "",
		};
		for (const k in o) console.log(k + "=" + (o[k] == null ? "" : o[k]));
	' 2>/dev/null
}
CFG_OUT="$(read_config_kv || true)"
cfgval() { echo "$CFG_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
SSO_HOST="$(cfgval SSO_HOST)"
PROXY_HOST="$(cfgval PROXY_HOST)"
ADMIN_UID="$(cfgval ADMIN_UID)"
ADMIN_PASS="$(cfgval ADMIN_PASS)"

info "Stack config:"
info "  SSO host:      https://${SSO_HOST}"
info "  Proxy host:    https://${PROXY_HOST}"
info "  Admin uid:     ${ADMIN_UID}"

# ── 5. Run the bootstrap (writes CLIENT_ID/CLIENT_SECRET/ALREADY_CONFIGURED) ──
# The bootstrap reads its inputs from /config/*.js (not env) and writes the
# generated OAuth client creds back into /config/proxy-secrets.js. No -e flags.
info "Running bootstrap (creates/updates the LDAP service account, first admin, OAuth client)..."
BOOTSTRAP_OUT=$("${COMPOSE[@]}" exec -T sso-manager node /bootstrap/bootstrap.js) \
	|| die "bootstrap failed:\n${BOOTSTRAP_OUT}"

getval() { echo "$BOOTSTRAP_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
CLIENT_ID=$(getval CLIENT_ID)
CLIENT_SECRET=$(getval CLIENT_SECRET)
ALREADY_CONFIGURED=$(getval ALREADY_CONFIGURED)
[[ -n "$CLIENT_ID" ]] || die "bootstrap did not return CLIENT_ID:\n${BOOTSTRAP_OUT}"

if [[ "$ALREADY_CONFIGURED" == "1" ]]; then
	info "Stack was already configured — OAuth client creds in proxy-secrets.js are current."
else
	info "OAuth client registered + creds written into $CONFIG_DIR/proxy-secrets.js."
fi

# ── 6. Start the proxy, wait for health ───────────────────────────────────────
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

# ── 7. Summary ───────────────────────────────────────────────────────────────
echo
info "\033[1;32mDone. Your SSO + proxy stack is up.\033[0m"
echo
echo "  SSO Manager UI:    https://${SSO_HOST}   (fronted by the proxy under TLS)"
echo "                      first-run fallback: http://127.0.0.1:${SSO_PORT:-3001}"
echo "  Proxy mgmt UI:      https://${PROXY_HOST}"
echo "                      first-run fallback: http://127.0.0.1:${MGMT_PORT:-3000}"
echo
echo "  First admin login:"
echo "    user: ${ADMIN_UID}"
echo "    pass: ${ADMIN_PASS}"
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