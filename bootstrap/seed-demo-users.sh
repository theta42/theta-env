#!/usr/bin/env bash
# seed-demo-users.sh — Seed realistic homelab/small-business demo users +
# groups into the SSO Manager's LDAP directory, for screenshots/demos.
#
# Mirrors the schema sso-manager-node's addLdapUser/addGroup actually write
# (see nodejs/models/user_ldap.js, group_ldap.js) so accounts created here are
# indistinguishable from ones created through the UI. Idempotent: safe to
# re-run, existing entries are skipped.
#
# Usage (from theta-env/):
#   docker compose exec -T sso-manager bash /bootstrap/seed-demo-users.sh
#
# Reads the real LDAP bind DN/password out of the mounted /config/sso-secrets.js
# at runtime rather than hardcoding them, so it keeps working if secrets rotate.

set -euo pipefail

LDAP_URL="ldap://localhost:389"
BIND_DN=$(node -e "console.log(require('/config/sso-secrets.js').ldap.bindDN)")
BIND_PW=$(node -e "console.log(require('/config/sso-secrets.js').ldap.bindPassword)")
BASE_DN=$(node -e "console.log(require('/config/sso-secrets.js').stack.ldapBaseDn)")
PEOPLE_OU="ou=people,${BASE_DN}"
GROUPS_OU="ou=groups,${BASE_DN}"

info()  { echo "[INFO] $*"; }
error() { echo "[ERROR] $*" >&2; }

ldap_exists() {
  ldapsearch -x -H "$LDAP_URL" -D "$BIND_DN" -w "$BIND_PW" -b "$1" -s base '(objectClass=*)' >/dev/null 2>&1
}

hash_password() {
  node -e "
    const crypto = require('crypto');
    const salt = crypto.randomBytes(8);
    const hash = crypto.createHash('sha512').update('$1').update(salt).digest();
    console.log('{SSHA512}' + Buffer.concat([hash, salt]).toString('base64'));
  "
}

# create_person <uid> <sn> <given_name> <mail> <uidNumber> <password> [description]
create_person() {
  local uid="$1" sn="$2" given="$3" mail="$4" uidnum="$5" pass="$6" desc="${7:-}"
  local person_dn="cn=${uid},${PEOPLE_OU}"
  local group_dn="cn=${uid},${GROUPS_OU}"

  if ldap_exists "$person_dn"; then
    info "User '${uid}' already exists — skipping"
    return 0
  fi

  local hash; hash=$(hash_password "$pass")
  local tmp; tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN

  cat > "$tmp" <<LDIF
dn: ${group_dn}
objectClass: posixGroup
objectClass: top
cn: ${uid}
gidNumber: ${uidnum}
description: Personal group for ${uid}

dn: ${person_dn}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: sudoRole
objectClass: ldapPublicKey
objectClass: top
objectClass: theta42Person
cn: ${uid}
sn: ${sn}
givenName: ${given}
uid: ${uid}
uidNumber: ${uidnum}
gidNumber: ${uidnum}
homeDirectory: /home/${uid}
loginShell: /bin/bash
mail: ${mail}
userPassword: ${hash}
description: ${desc:- }
sudoHost: ALL
sudoCommand: ALL
sudoUser: ${uid}
LDIF

  ldapadd -x -H "$LDAP_URL" -D "$BIND_DN" -w "$BIND_PW" -f "$tmp"
  info "Created user '${uid}' (${mail})"
}

# create_group <cn> <owner_dn> <description>
create_group() {
  local cn="$1" owner_dn="$2" desc="$3"
  local group_dn="cn=${cn},${GROUPS_OU}"

  if ldap_exists "$group_dn"; then
    info "Group '${cn}' already exists — skipping"
    return 0
  fi

  ldapadd -x -H "$LDAP_URL" -D "$BIND_DN" -w "$BIND_PW" <<LDIF
dn: ${group_dn}
objectClass: groupOfNames
objectClass: top
cn: ${cn}
description: ${desc}
member: ${owner_dn}
LDIF
  info "Created group '${cn}'"
}

# add_member <group_cn> <user_dn>
add_member() {
  local cn="$1" user_dn="$2"
  local group_dn="cn=${cn},${GROUPS_OU}"
  ldapmodify -x -H "$LDAP_URL" -D "$BIND_DN" -w "$BIND_PW" 2>/dev/null <<LDIF || true
dn: ${group_dn}
changetype: modify
add: member
member: ${user_dn}
LDIF
}

info "Waiting for LDAP at ${LDAP_URL}..."
for i in $(seq 1 30); do
  ldapsearch -x -H "$LDAP_URL" -b '' -s base '(objectClass=*)' >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && { error "LDAP not reachable"; exit 1; }
  sleep 1
done

# ── Demo users (homelab / small-business cast) ───────────────────────────────
# uidNumbers start at 5000 to stay well clear of the app's own auto-assigned
# range (nextPosixId scans existing entries and increments from the highest).
# See docs/fixtures.md for the canonical list this mirrors — update both
# together.
create_person schen      Chen      Sarah  sarah.chen@laptop-dev.vm42.us     5000 'DemoPass123!' 'Engineering — DevOps lead'
create_person dkim       Kim       David  david.kim@laptop-dev.vm42.us      5001 'DemoPass123!' 'Engineering — Backend developer'
create_person ppatel     Patel     Priya  priya.patel@laptop-dev.vm42.us    5002 'DemoPass123!' 'Engineering — Frontend developer'
create_person mjohnson   Johnson   Marcus marcus.johnson@laptop-dev.vm42.us 5003 'DemoPass123!' 'Finance — Finance manager'
create_person lnguyen    Nguyen    Linda  linda.nguyen@laptop-dev.vm42.us   5004 'DemoPass123!' 'Finance — Bookkeeper'
create_person erodriguez Rodriguez Emily  emily.rodriguez@laptop-dev.vm42.us 5005 'DemoPass123!' 'Support — Support lead'
create_person tbaker     Baker     Tom    tom.baker@laptop-dev.vm42.us      5006 'DemoPass123!' 'Support — Support tech'
create_person jwilson    Wilson    James  james.wilson@laptop-dev.vm42.us   5007 'DemoPass123!' 'Management — Owner'
create_person svc-monitoring Bot  monitoring monitoring@laptop-dev.vm42.us  5008 'ServiceAcct!2024' 'Service account — Grafana/Prometheus scraping'
create_person svc-backup     Bot  backup     backup@laptop-dev.vm42.us     5009 'ServiceAcct!2024' 'Service account — backup automation'

# ── Department groups (groupOfNames — what shows up in Directory > Groups) ──
ADMIN_DN="cn=admin,${PEOPLE_OU}"
create_group engineering "$ADMIN_DN" "Engineering team"
create_group finance     "$ADMIN_DN" "Finance and accounting"
create_group support     "$ADMIN_DN" "Support and operations"
create_group management  "$ADMIN_DN" "Company management"

add_member engineering "cn=schen,${PEOPLE_OU}"
add_member engineering "cn=dkim,${PEOPLE_OU}"
add_member engineering "cn=ppatel,${PEOPLE_OU}"
add_member finance     "cn=mjohnson,${PEOPLE_OU}"
add_member finance     "cn=lnguyen,${PEOPLE_OU}"
add_member support     "cn=erodriguez,${PEOPLE_OU}"
add_member support     "cn=tbaker,${PEOPLE_OU}"
add_member management  "cn=jwilson,${PEOPLE_OU}"

# Mark the service accounts as service accounts (app_sso_service_account is
# seeded by the app itself on boot, so it should already exist).
if ldap_exists "cn=app_sso_service_account,${GROUPS_OU}"; then
  add_member app_sso_service_account "cn=svc-monitoring,${PEOPLE_OU}"
  add_member app_sso_service_account "cn=svc-backup,${PEOPLE_OU}"
else
  info "app_sso_service_account group not found — skipping service-account tagging"
fi

info "Demo data seed complete."
