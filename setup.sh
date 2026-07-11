#!/usr/bin/env bash
#
# theta-env setup — one-command bring-up of the unified SSO Manager + Proxy stack.
#
#   git clone --recursive <theta-env> && cd theta-env
#   cp .env.example .env   # edit the REQUIRED values
#   ./setup.sh
#
# Idempotent: safe to re-run. It (re)starts the SSO Manager, runs the bootstrap
# (which converges the LDAP service account / first admin / OAuth client to the
# .env values), writes ./proxy.env (the proxy's env_file), then starts the proxy.
#
# What it does, in order:
#   1. Validate .env (copy from .env.example if missing) + the REQUIRED values.
#   2. docker compose up -d sso-manager; wait for /health.
#   3. docker compose exec sso-manager node /bootstrap/bootstrap.js
#      -> prints CLIENT_ID / CLIENT_SECRET / ALREADY_CONFIGURED on stdout.
#   4. Write ./proxy.env from .env + the bootstrap output (the proxy's app_* env).
#   5. docker compose up -d proxy; wait for /health.
#   6. Print the first-admin login + the public URLs.
#
# Requires: docker + docker compose (v1 standalone or v2 plugin). The compose
# file uses `version: '3.8'` + single-level ${VAR} interpolation so v1 works.

set -euo pipefail

cd "$(dirname "$0")"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# Detect docker compose (v2 plugin `docker compose` or v1 standalone `docker-compose`).
if docker compose version >/dev/null 2>&1; then
	COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
	COMPOSE=(docker-compose)
else
	die "docker compose not found. Install Docker Compose (v2 plugin or v1 standalone)."
fi

# ── 1. Load + validate .env ───────────────────────────────────────────────────
if [[ ! -f .env ]]; then
	if [[ -f .env.example ]]; then
		cp .env.example .env
		info "Created .env from .env.example — EDIT IT and re-run ./setup.sh."
		info "Required: LDAP_ADMIN_PASS, JWT_SECRET, SSO_HOST, PROXY_HOST, BOOTSTRAP_ADMIN_PASS."
		exit 0
	else
		die ".env not found and no .env.example to copy from."
	fi
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

require() { [[ -n "${!1:-}" ]] || die ".env is missing required key: $1"; }
require LDAP_BASE_DN
require LDAP_ADMIN_PASS
require SSO_HOST
require PROXY_HOST
require BOOTSTRAP_ADMIN_UID
require BOOTSTRAP_ADMIN_PASS

# JWT_SECRET: generate + persist if blank (so it survives re-runs).
if [[ -z "${JWT_SECRET:-}" ]]; then
	if command -v openssl >/dev/null 2>&1; then
		JWT_SECRET=$(openssl rand -hex 32)
	else
		JWT_SECRET="theta-env-jwt-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' ')"
	fi
	if grep -q '^JWT_SECRET=' .env; then
		sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" .env
	else
		printf 'JWT_SECRET=%s\n' "$JWT_SECRET" >> .env
	fi
	info "Generated + persisted JWT_SECRET into .env (save it — it signs all tokens)."
fi

# Default BOOTSTRAP_ADMIN_EMAIL if blank.
BOOTSTRAP_ADMIN_EMAIL="${BOOTSTRAP_ADMIN_EMAIL:-admin@${PROXY_HOST}}"
# Default LDAP_SERVICE_PASS if blank (random).
if [[ -z "${LDAP_SERVICE_PASS:-}" ]]; then
	if command -v openssl >/dev/null 2>&1; then
		LCD=$(openssl rand -hex 16)
	else
		LCD="svc-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' ')"
	fi
	LDAP_SERVICE_PASS="$LCD"
	if grep -q '^LDAP_SERVICE_PASS=' .env; then
		sed -i "s|^LDAP_SERVICE_PASS=.*|LDAP_SERVICE_PASS=${LDAP_SERVICE_PASS}|" .env
	else
		printf 'LDAP_SERVICE_PASS=%s\n' "$LDAP_SERVICE_PASS" >> .env
	fi
	info "Generated + persisted LDAP_SERVICE_PASS into .env."
fi

info "Stack config:"
info "  Base DN:      ${LDAP_BASE_DN}"
info "  SSO host:      https://${SSO_HOST}"
info "  Proxy host:    https://${PROXY_HOST}"
info "  Admin uid:     ${BOOTSTRAP_ADMIN_UID}"

# ── 2. Start SSO Manager, wait for health ─────────────────────────────────────
info "Building + starting sso-manager (first run builds the image; this takes a while)..."
"${COMPOSE[@]}" up -d --build sso-manager

info "Waiting for sso-manager to be healthy..."
for i in $(seq 1 60); do
	status=$("${COMPOSE[@]}" ps -o json sso-manager 2>/dev/null \
	         | grep -o '"Health":"healthy"' || true)
	if [[ -n "$status" ]]; then info "sso-manager is healthy."; break; fi
	# Fall back to probing /health directly (compose v1 lacks `ps -o json`).
	if docker exec sso-manager wget -q -O- http://localhost:3001/health >/dev/null 2>&1; then
		info "sso-manager is healthy (probed /health)."; break
	fi
	if (( i == 60 )); then die "sso-manager did not become healthy in 60s. Check: ${COMPOSE[*]} logs sso-manager"; fi
	sleep 2
done

# ── 3. Run the bootstrap (writes CLIENT_ID/CLIENT_SECRET/ALREADY_CONFIGURED) ──
# PROXY_ENV_EXISTS tells the bootstrap whether to rotate the client secret: if
# proxy.env already exists, keep the existing secret (the proxy can still read
# it); if not, rotate so a wiped-and-restored proxy gets a usable secret.
PROXY_ENV_EXISTS=0
[[ -f ./proxy.env ]] && PROXY_ENV_EXISTS=1

info "Running bootstrap (creates/updates the LDAP service account, first admin, OAuth client)..."
BOOTSTRAP_OUT=$("${COMPOSE[@]}" exec -T \
	-e LDAP_BASE_DN="${LDAP_BASE_DN}" \
	-e LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS}" \
	-e BOOTSTRAP_ADMIN_UID="${BOOTSTRAP_ADMIN_UID}" \
	-e BOOTSTRAP_ADMIN_PASS="${BOOTSTRAP_ADMIN_PASS}" \
	-e BOOTSTRAP_ADMIN_EMAIL="${BOOTSTRAP_ADMIN_EMAIL}" \
	-e LDAP_SERVICE_PASS="${LDAP_SERVICE_PASS}" \
	-e SSO_HOST="${SSO_HOST}" \
	-e PROXY_HOST="${PROXY_HOST}" \
	-e PROXY_ENV_EXISTS="${PROXY_ENV_EXISTS}" \
	sso-manager node /bootstrap/bootstrap.js) \
	|| die "bootstrap failed:\n${BOOTSTRAP_OUT}"

# Parse KEY=VALUE lines from stdout (bootstrap logs go to stderr, so this is clean).
getval() { echo "$BOOTSTRAP_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
CLIENT_ID=$(getval CLIENT_ID)
CLIENT_SECRET=$(getval CLIENT_SECRET)
ALREADY_CONFIGURED=$(getval ALREADY_CONFIGURED)
[[ -n "$CLIENT_ID" ]] || die "bootstrap did not return CLIENT_ID:\n${BOOTSTRAP_OUT}"
[[ -n "$CLIENT_SECRET" ]] || die "bootstrap did not return CLIENT_SECRET:\n${BOOTSTRAP_OUT}"

# ── 4. Write ./proxy.env (the proxy's env_file) ───────────────────────────────
# All app_* so the proxy reads them via @simpleworkjs/conf (>=1.1.0) env overrides.
# Browser-facing endpoints use https://${SSO_HOST}; server-to-server
# token/userinfo use the internal http://sso-manager:3001 (no hairpin through the
# public TLS listener). LDAP over LDAPS on the docker network with the SSO's
# self-signed cert (rejectUnauthorized=false). adminGroups + adminUsers are JSON
# arrays (conf coerces via JSON.parse).
if [[ "$CLIENT_SECRET" == "__UNCHANGED__" ]]; then
	if [[ -f ./proxy.env ]]; then
		info "proxy.env exists and client unchanged — preserving existing proxy.env."
		CLIENT_SECRET=$(grep -m1 '^app_oidc__clientSecret=' ./proxy.env | cut -d= -f2-)
		[[ -n "$CLIENT_SECRET" ]] || die "proxy.env exists but has no app_oidc__clientSecret; delete it and re-run."
	else
		# Shouldn't happen (bootstrap only emits __UNCHANGED__ when proxy.env exists),
		# but recover by rotating: re-run bootstrap with PROXY_ENV_EXISTS=0.
		die "proxy.env missing but bootstrap said unchanged. Delete proxy.env if present and re-run."
	fi
fi

info "Writing ./proxy.env (proxy app_* config)..."
cat > ./proxy.env << PROXYEOF
# Generated by setup.sh from .env + the bootstrap output. DO NOT COMMIT.
# The proxy reads these via @simpleworkjs/conf app_* env overrides.

# ── OIDC (browser-facing endpoints use the public SSO URL; token/userinfo use
#    the internal docker-network URL so the proxy never hairpins through TLS).
app_oidc__issuer=https://${SSO_HOST}
app_oidc__authorizationEndpoint=https://${SSO_HOST}/oauth/authorize
app_oidc__endSessionEndpoint=https://${SSO_HOST}/oauth/logout
app_oidc__tokenEndpoint=http://sso-manager:3001/oauth/token
app_oidc__userinfoEndpoint=http://sso-manager:3001/oauth/userinfo
app_oidc__clientId=${CLIENT_ID}
app_oidc__clientSecret=${CLIENT_SECRET}
app_oidc__redirectUri=https://${PROXY_HOST}/api/auth/oidc/callback
app_oidc__enabled=true

# ── LDAP (direct bind over LDAPS on the docker network; self-signed cert).
app_ldap__url=ldaps://sso-manager:636
app_ldap__bindDN=cn=ldapclient,ou=people,${LDAP_BASE_DN}
app_ldap__bindPassword=${LDAP_SERVICE_PASS}
app_ldap__searchBase=ou=people,${LDAP_BASE_DN}
app_ldap__userFilter=(objectClass=posixAccount)
app_ldap__tlsOptions__rejectUnauthorized=false

# ── Auth (anti-lockout: the local proxyadmin2 user + SSO admin group).
app_auth__adminGroups=["app_sso_admin"]
app_auth__adminUsers=["proxyadmin2"]
PROXYEOF
chmod 600 ./proxy.env

if [[ "$ALREADY_CONFIGURED" == "1" ]]; then
	info "Stack was already configured — proxy.env refreshed with current creds."
else
	info "OAuth client registered + proxy.env written."
fi

# ── 5. Start the proxy, wait for health ───────────────────────────────────────
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

# ── 6. Summary ───────────────────────────────────────────────────────────────
echo
info "\033[1;32mDone. Your SSO + proxy stack is up.\033[0m"
echo
echo "  SSO Manager UI:    https://${SSO_HOST}   (fronted by the proxy under TLS)"
echo "                      first-run fallback: http://127.0.0.1:${SSO_PORT:-3001}"
echo "  Proxy mgmt UI:      https://${PROXY_HOST}"
echo "                      first-run fallback: http://127.0.0.1:${MGMT_PORT:-3000}"
echo
echo "  First admin login:"
echo "    user: ${BOOTSTRAP_ADMIN_UID}"
echo "    pass: ${BOOTSTRAP_ADMIN_PASS}"
echo
echo "  Next: add DNS records (or /etc/hosts) pointing ${SSO_HOST} and ${PROXY_HOST}"
echo "        at this host, then open https://${SSO_HOST} and log in as the admin."
echo "        The proxy auto-issues Let's Encrypt certs if port 80 is reachable;"
echo "        otherwise it serves a self-signed fallback on the LAN."
echo
echo "  Re-run ./setup.sh any time to converge the stack to .env (idempotent)."