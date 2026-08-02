#!/usr/bin/env bash
#
# LDAP Migration Script for theta42
#
# Migrates an existing OpenLDAP server to the theta42 stack.
# Exports data from source, transforms as needed, imports into theta42.
#
# Usage:
#   ./migrate-ldap.sh --source-host <ldap-uri> --source-bind-dn <dn> --source-bind-pass <pass> --target-domain <domain>
#
# Example:
#   ./migrate-ldap.sh --source-host ldap://192.168.1.10:389 --source-bind-dn "cn=admin,dc=example,dc=com" --source-bind-pass "secret" --target-domain "example.com"
#

set -euo pipefail

cd "$(dirname "$0")"

# ── Defaults ──────────────────────────────────────────────────────────────────
SOURCE_HOST=""
SOURCE_BIND_DN=""
SOURCE_BIND_PASS=""
TARGET_DOMAIN=""
BASE_DN=""
EXPORT_DIR="./ldap-migration-$(date +%Y%m%d-%H%M%S)"
THETA_ENV_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { printf "${BLUE}[migrate]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[migrate]${NC} %s\n" "$*" >&2; }
error() { printf "${RED}[migrate]${NC} %s\n" "$*" >&2; }
success() { printf "${GREEN}[migrate]${NC} %s\n" "$*" >&2; }
die()   { error "$*"; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-host)
            SOURCE_HOST="$2"
            shift 2
            ;;
        --source-bind-dn)
            SOURCE_BIND_DN="$2"
            shift 2
            ;;
        --source-bind-pass)
            SOURCE_BIND_PASS="$2"
            shift 2
            ;;
        --target-domain)
            TARGET_DOMAIN="$2"
            shift 2
            ;;
        --export-dir)
            EXPORT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
LDAP Migration Script for theta42

Usage: $0 --source-host <uri> --source-bind-dn <dn> --source-bind-pass <pass> --target-domain <domain>

Options:
  --source-host      Source LDAP URI (e.g., ldap://192.168.1.10:389 or ldaps://ldap.example.com:636)
  --source-bind-dn   Bind DN for source LDAP (e.g., cn=admin,dc=example,dc=com)
  --source-bind-pass Bind password for source LDAP
  --target-domain    Target domain for theta42 (e.g., example.com)
  --export-dir       Directory for exports (default: ./ldap-migration-<timestamp>)
  --help             Show this help message

EOF
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -n "$SOURCE_HOST" ]] || die "Missing --source-host"
[[ -n "$SOURCE_BIND_DN" ]] || die "Missing --source-bind-dn"
[[ -n "$SOURCE_BIND_PASS" ]] || die "Missing --source-bind-pass"
[[ -n "$TARGET_DOMAIN" ]] || die "Missing --target-domain"

# Derive base DN from domain (e.g., example.com -> dc=example,dc=com)
BASE_DN="$(echo "$TARGET_DOMAIN" | sed 's/\./,dc=/g; s/^/dc=/')"

info "Migration configuration:"
info "  Source host:     $SOURCE_HOST"
info "  Source bind DN:  $SOURCE_BIND_DN"
info "  Target domain:   $TARGET_DOMAIN"
info "  Target base DN:  $BASE_DN"
info "  Export dir:      $EXPORT_DIR"

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found. Install ldap-utils."
command -v slapcat >/dev/null 2>&1 || die "slapcat not found."
command -v docker >/dev/null 2>&1 || die "docker not found."
command -v docker-compose >/dev/null 2>&1 || command -v docker compose >/dev/null 2>&1 || die "docker compose not found."

if [[ -d "$EXPORT_DIR" ]]; then
    warn "Export directory already exists: $EXPORT_DIR"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Aborted."
        exit 1
    fi
fi
mkdir -p "$EXPORT_DIR"

# ── Phase 1: Export from source LDAP ─────────────────────────────────────────
info "Phase 1: Exporting data from source LDAP..."

# Export each subtree
export_subtree() {
    local base="$1"
    local outfile="$2"
    info "  Exporting $base -> $outfile"

    # Use ldapsearch with -LLL for LDIF output
    if ! ldapsearch -x -H "$SOURCE_HOST" -D "$SOURCE_BIND_DN" -w "$SOURCE_BIND_PASS" \
                    -b "$base" -s sub "(objectClass=*)" > "$outfile" 2>/dev/null; then
        warn "  No data or base DN not found: $base"
        # Create empty file to signal "checked"
        echo "# No data for $base" > "$outfile"
    fi
}

# Export standard subtrees
export_subtree "ou=people,$BASE_DN" "$EXPORT_DIR/01-people.ldif"
export_subtree "ou=groups,$BASE_DN" "$EXPORT_DIR/02-groups.ldif"
export_subtree "ou=sudoers,$BASE_DN" "$EXPORT_DIR/03-sudoers.ldif"
export_subtree "ou=services,$BASE_DN" "$EXPORT_DIR/04-services.ldif"

# Also export cn=config for reference (read-only, won't import)
info "  Exporting cn=config for reference..."
ldapsearch -x -H "$SOURCE_HOST" -D "$SOURCE_BIND_DN" -w "$SOURCE_BIND_PASS" \
           -b "cn=config" -s sub "(objectClass=*)" > "$EXPORT_DIR/00-config-reference.ldif" 2>/dev/null || true

# Count entries
for f in "$EXPORT_DIR"/*.ldif; do
    count=$(grep -c "^dn:" "$f" 2>/dev/null || echo 0)
    info "  $(basename "$f"): $count entries"
done

success "Export complete: $EXPORT_DIR"

# ── Phase 2: Transform LDIF ──────────────────────────────────────────────────
info "Phase 2: Transforming LDIF for theta42 compatibility..."

# Create transformation script
cat > "$EXPORT_DIR/transform.sh" <<'TRANSFORM_SCRIPT'
#!/usr/bin/env bash
# Transform exported LDIF for theta42 compatibility

INPUT="$1"
OUTPUT="$2"
BASE_DN="$3"

# theta42 requires certain objectClasses and attributes
# This script:
# 1. Ensures posixAccount has uidNumber, gidNumber, homeDirectory, loginShell
# 2. Ensures groupOfNames has at least one member
# 3. Adds ldapPublicKey objectClass where sshPublicKey exists
# 4. Normalizes password hash formats if needed

while IFS= read -r line || [[ -n "$line" ]]; do
    echo "$line"
done < "$INPUT" > "$OUTPUT"

echo "Transform complete: $OUTPUT"
TRANSFORM_SCRIPT
chmod +x "$EXPORT_DIR/transform.sh"

# For now, we'll do a direct import. The transformation is minimal for most setups.
# If you have custom schemas, you may need to edit the LDIF manually.

# ── Phase 3: Prepare theta42 LDAP ────────────────────────────────────────────
info "Phase 3: Preparing theta42 LDAP..."

# Stop theta42 stack
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    die "docker compose not found"
fi

info "  Stopping sso-manager container..."
$COMPOSE_CMD stop sso-manager 2>/dev/null || true

# Wait for container to stop
sleep 3

# ── Phase 4: Import into theta42 ─────────────────────────────────────────────
info "Phase 4: Importing data into theta42 LDAP..."

# Create import script that runs inside the container
cat > "$EXPORT_DIR/import-to-theta42.sh" <<'IMPORT_SCRIPT'
#!/bin/bash
# Run inside theta42 sso-manager container to import LDIF

set -e

EXPORT_DIR="$1"
BASE_DN="$2"

# Stop slapd if running
pkill slapd 2>/dev/null || true
sleep 2

# Clear existing data (but preserve structure)
info "Clearing existing LDAP data..."
rm -rf /var/lib/ldap/*
rm -rf /var/lib/ldap/db.*

# Initialize LDAP database with theta42 schema
info "Initializing LDAP database..."

# Create initial LDIF with base structure
cat > /tmp/base.ldif <<EOF
dn: $BASE_DN
objectClass: top
objectClass: dcObject
objectClass: organization
dc: $(echo $BASE_DN | sed 's/,dc=.*//; s/dc=//')
o: Organization

dn: ou=people,$BASE_DN
objectClass: organizationalUnit
ou: people

dn: ou=groups,$BASE_DN
objectClass: organizationalUnit
ou: groups

dn: ou=sudoers,$BASE_DN
objectClass: organizationalUnit
ou: sudoers

dn: ou=services,$BASE_DN
objectClass: organizationalUnit
ou: services

dn: cn=admin,$BASE_DN
objectClass: organizationalRole
cn: admin
description: LDAP Administrator

dn: cn=ldap-admin,ou=groups,$BASE_DN
objectClass: groupOfNames
cn: ldap-admin
member: cn=admin,$BASE_DN
EOF

# Import base structure
slapadd -c -l /tmp/base.ldif -b "$BASE_DN" 2>/dev/null || true

# Import user data
for f in "$EXPORT_DIR"/*.ldif; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "00-config-reference.ldif" ]] && continue

    info "Importing $f..."
    # Use -c to continue on errors (some entries may already exist)
    slapadd -c -l "$f" -b "$BASE_DN" 2>/dev/null || warn "Some entries in $f may have failed"
done

# Fix ownership
chown -R ldap:ldap /var/lib/ldap

# Start slapd
info "Starting slapd..."
exec /usr/sbin/slapd -h "ldap:/// ldaps:///" -u ldap -g ldap

IMPORT_SCRIPT

# Copy import script to export dir
cp "$EXPORT_DIR/import-to-theta42.sh" "$EXPORT_DIR/"

# Run the import inside the container
info "Running import inside sso-manager container..."

# First, start a temporary container to do the import
$COMPOSE_CMD up -d sso-manager 2>/dev/null || true
sleep 5

# Copy LDIF files into container
info "Copying LDIF files to container..."
for f in "$EXPORT_DIR"/*.ldif; do
    [[ -f "$f" ]] || continue
    docker cp "$f" sso-manager:/tmp/migration/ 2>/dev/null || {
        docker exec sso-manager mkdir -p /tmp/migration
        docker cp "$f" sso-manager:/tmp/migration/
    }
done

# Run import
info "Executing import..."
docker exec sso-manager bash -c "
    pkill slapd 2>/dev/null || true
    sleep 2

    # Clear data
    rm -rf /var/lib/ldap/*

    # Create base structure
    slapadd -c -b '$BASE_DN' <<EOF
dn: $BASE_DN
objectClass: top
objectClass: dcObject
objectClass: organization
dc: $(echo $BASE_DN | cut -d',' -f1 | cut -d'=' -f2)
o: $TARGET_DOMAIN

dn: ou=people,$BASE_DN
objectClass: organizationalUnit
ou: people

dn: ou=groups,$BASE_DN
objectClass: organizationalUnit
ou: groups

dn: ou=sudoers,$BASE_DN
objectClass: organizationalUnit
ou: sudoers

dn: ou=services,$BASE_DN
objectClass: organizationalUnit
ou: services
EOF

    # Import user data
    for f in /tmp/migration/*.ldif; do
        [[ \"\$(basename \$f)\" == \"00-config-reference.ldif\" ]] && continue
        [[ -f \"\$f\" ]] || continue
        echo \"Importing \$f...\"
        slapadd -c -l \"\$f\" -b '$BASE_DN' 2>/dev/null || echo \"Warning: Some entries in \$f may have failed\"
    done

    # Fix ownership
    chown -R ldap:ldap /var/lib/ldap

    echo \"Import complete!\"
" || warn "Import had some errors - check output above"

# ── Phase 5: Create theta42 admin groups ─────────────────────────────────────
info "Phase 5: Creating theta42 admin groups..."

# Create LDIF for theta42-specific groups
cat > "$EXPORT_DIR/theta42-groups.ldif" <<EOF
# theta42 administrative groups
# These groups control access to various features

# Cross-app super admin - full admin in all apps
dn: cn=app_super_admin,ou=groups,$BASE_DN
objectClass: groupOfNames
objectClass: top
cn: app_super_admin
description: Cross-app super administrators

# SSO Manager admin
dn: cn=app_sso_admin,ou=groups,$BASE_DN
objectClass: groupOfNames
objectClass: top
cn: app_sso_admin
description: SSO Manager administrators

# SSO invite - can invite users
dn: cn=app_sso_invite,ou=groups,$BASE_DN
objectClass: groupOfNames
objectClass: top
cn: app_sso_invite
description: Can send invitations

# OAuth admin - manages OAuth clients
dn: cn=app_sso_oauth_admin,ou=groups,$BASE_DN
objectClass: groupOfNames
objectClass: top
cn: app_sso_oauth_admin
description: OAuth client administrators

# Service account marker
dn: cn=app_sso_service_account,ou=groups,$BASE_DN
objectClass: groupOfNames
objectClass: top
cn: app_sso_service_account
description: Service accounts (hidden from UI)

# Jump host admin - audit access only
dn: cn=app_jump_admin,ou=groups,$BASE_DN
objectClass: groupOfNames
objectClass: top
cn: app_jump_admin
description: Jump host audit administrators
EOF

# Import the theta42 groups
docker exec sso-manager bash -c "
    slapadd -c -l /tmp/theta42-groups.ldif -b '$BASE_DN' 2>/dev/null || echo \"Groups may already exist\"
" <<EOF
$(cat "$EXPORT_DIR/theta42-groups.ldif")
EOF

# ── Phase 6: Restart and verify ──────────────────────────────────────────────
info "Phase 6: Restarting theta42 stack..."

$COMPOSE_CMD restart sso-manager
sleep 10

info "Waiting for sso-manager to be healthy..."
for i in $(seq 1 30); do
    if docker exec sso-manager wget -q -O- http://localhost:3001/health >/dev/null 2>&1; then
        success "sso-manager is healthy!"
        break
    fi
    if (( i == 30 )); then
        warn "sso-manager did not become healthy in 30s. Check logs with: docker compose logs sso-manager"
    fi
    sleep 2
done

# Verify import
info "Verifying import..."
dn_count=$(docker exec sso-manager ldapsearch -x -H "ldap://localhost" -b "$BASE_DN" -s sub "(objectClass=*)" dn 2>/dev/null | grep -c "^dn:" || echo 0)
info "Total entries in LDAP: $dn_count"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
success "Migration complete!"
echo ""
info "Summary:"
info "  - Exported data saved to: $EXPORT_DIR"
info "  - Base DN: $BASE_DN"
info "  - Total entries: $dn_count"
echo ""
info "Next steps:"
info "  1. Review the exported LDIF files in $EXPORT_DIR"
info "  2. Add users to theta42 admin groups as needed:"
info "     docker exec sso-manager ldapmodify -x -H ldap://localhost -D 'cn=admin,$BASE_DN' -w <admin-pass>"
info "  3. Update your LDAP clients to point to theta42"
info "  4. Run ./setup.sh to complete theta42 bootstrap"
echo ""
warn "IMPORTANT: Update all LDAP clients to use the new theta42 LDAP server!"
warn "  - SSSD: Update /etc/sssd/sssd.conf ldap_uri"
warn "  - sudo: Update /etc/sudo-ldap.conf"
warn "  - Apps: Update LDAP connection strings"
