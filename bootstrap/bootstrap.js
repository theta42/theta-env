#!/usr/bin/env node
/*
 * theta-suite bootstrap — runs inside the sso-manager container to wire the
 * proxy into a (fresh or existing) SSO Manager. Invoked by setup.sh:
 *
 *   docker compose exec sso-manager node /bootstrap/bootstrap.js
 *
 * It is intentionally self-contained: only Node built-ins (child_process,
 * crypto, fs) + global fetch. No requiring of the SSO's internal models (which
 * would read the wrong conf.ldap in a docker-exec process and risk model side
 * effects). LDAP ops use the openldap-clients binaries (ldapadd / ldapsearch /
 * ldapmodify) with explicit admin creds; the OAuth client is created via the
 * SSO's own HTTP API (logging in as the bootstrapped admin, which also
 * validates the admin password end-to-end).
 *
 * Config is read from the bind-mounted ./config/ directory (at /config in the
 * container), NOT from environment variables:
 *   /config/sso-secrets.js    — directory root creds, first admin, service
 *                               account pass, public hostnames, base DN
 *   /config/proxy-secrets.js  — the proxy's OIDC client creds (clientId /
 *                               clientSecret). The SSO *generates* these on
 *                               client create, so this script writes them back
 *                               into the file (the sso-manager mounts ./config
 *                               read-write for this purpose).
 *
 * Generated creds are ALSO written into OpenBao (secret/proxy/conf and, when
 * the jump host is enabled, secret/jump-host/conf) so the proxy + jump host
 * load them from OpenBao at boot via @simpleworkjs/bao-conf. setup.sh passes
 * the root VAULT_TOKEN on this exec for that purpose. The OpenBao write is
 * fail-soft: if VAULT_TOKEN is unset or OpenBao is unreachable, the /config
 * file remains the fallback and bootstrap does not fail the bring-up over it.
 *
 * Idempotent: re-running converges to the ./config values. The LDAP service
 * account + admin passwords are reset to the file values on each run; the
 * OAuth client is created if missing. If proxy-secrets.js already holds a
 * clientId+clientSecret matching an existing client, they are kept (the proxy
 * keeps working). If the client is missing but the file has creds, a new client
 * is created and the file is updated. The secret is rotated only when a client
 * exists but the file has no usable secret to recover.
 *
 * Output (stdout, KEY=VALUE for setup.sh to parse): CLIENT_ID, CLIENT_SECRET,
 * ALREADY_CONFIGURED. Progress logs go to stderr.
 */
'use strict';

const { execFileSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');

// ── Read config from the mounted ./config/ (NOT env) ─────────────────────────
const sso   = require('/config/sso-secrets.js');
const proxy = require('/config/proxy-secrets.js');

function requireConf(value, name) {
	if (value === undefined || value === null || value === '' || value === 'CHANGE-ME') {
		throw new Error(`${name} is not configured in /config/sso-secrets.js`);
	}
	return value;
}

const BASE_DN        = requireConf((sso.stack && sso.stack.ldapBaseDn), 'stack.ldapBaseDn');
const ADMIN_PASS     = requireConf((sso.ldap && sso.ldap.bindPassword), 'ldap.bindPassword');
const BIND_DN        = `cn=admin,${BASE_DN}`;
const LDAP_URL       = 'ldap://localhost:389';

const ADMIN_UID      = (sso.bootstrap && sso.bootstrap.adminUid) || 'admin';
// The first admin *user's* password (cn=<uid>,ou=people,<base>). Distinct from
// ADMIN_PASS above, which is the LDAP *root* (cn=admin,<base>) bind password —
// two different accounts, two different secrets.
const ADMIN_USER_PASS = requireConf((sso.bootstrap && sso.bootstrap.adminPass), 'bootstrap.adminPass');
const ADMIN_EMAIL    = (sso.bootstrap && sso.bootstrap.adminEmail) || '';
const SVC_PASS       = requireConf(sso.serviceAccountPass, 'serviceAccountPass');

const SSO_HOST   = (sso.stack && sso.stack.ssoHost)   || 'sso.example.com';
const PROXY_HOST = (sso.stack && sso.stack.proxyHost) || 'proxy.example.com';

// OAuth client creds the proxy will use. The SSO generates these on create;
// proxy-secrets.js starts with placeholders, and this script writes the real
// values back (writeProxyCreds below).
const EXISTING_ID     = (proxy.oidc && proxy.oidc.clientId) || '';
const EXISTING_SECRET = (proxy.oidc && proxy.oidc.clientSecret) || '';
const PLACEHOLDER = /^set-me$|^$/;
const HAS_USABLE_CREDS = EXISTING_ID && EXISTING_SECRET
	&& !PLACEHOLDER.test(EXISTING_ID) && !PLACEHOLDER.test(EXISTING_SECRET);

const REDIRECT_URI = `https://${PROXY_HOST}/api/auth/oidc/callback`;

// Per-host SSO (proxy routes/host_auth.js) calls back to
// `https://<proxied-host>/__proxy_auth/callback` — a DIFFERENT URL for every
// host the proxy fronts, all against this one OAuth client. Registering just
// REDIRECT_URI above is what produced "400 redirect_uri is not registered for
// this client" the moment a host's auth was set to SSO. The SSO's
// redirectUriAllowed() supports `**` (any number of labels), so one pattern
// covers the whole domain; `**.` does not match the bare apex, so register that
// separately for a host served at the domain itself.
//
// A function, not a const: DOMAIN is declared further down this file, so
// evaluating it here at module scope would hit the temporal dead zone.
function proxyRedirectUris() {
	if (!DOMAIN) return [REDIRECT_URI];
	return [
		REDIRECT_URI,
		`https://**.${DOMAIN}/__proxy_auth/callback`,
		`https://${DOMAIN}/__proxy_auth/callback`,
	];
}
const SSO_INTERNAL = 'http://localhost:3001';
const CLIENT_NAME = 'theta-proxy';

const ADMIN_DN  = `cn=${ADMIN_UID},ou=people,${BASE_DN}`;
const SVC_DN    = `cn=ldapclient,ou=people,${BASE_DN}`;
// god_admin is the global super group (docs/GROUPS.md §2); the bootstrapped
// admin is its first member. app_sso_admin / app_sso_oauth_admin are the
// per-console admin groups still used by the SSO UI. god_admin is nested into
// the app_sso_* groups (and every resource's _admin group) by
// docker-entrypoint.sh + api_directory_admin, so LDAP-level consumers (SSSD,
// sudo) resolve it transitively.
const ADMIN_GROUPS = ['god_admin', 'app_sso_admin', 'app_sso_oauth_admin'];

const log  = (...a) => process.stderr.write('[bootstrap] ' + a.join(' ') + '\n');
const out  = (k, v) => process.stdout.write(`${k}=${v}\n`);

// ── OpenBao (Vault) writes ───────────────────────────────────────────────────
// bootstrap generates the proxy's + jump host's OAuth client creds and writes
// them back into /config/*-secrets.js (the file fallback). It ALSO writes the
// complete conf into OpenBao so the proxy + jump host load it from there at
// boot via @simpleworkjs/bao-conf. setup.sh passes the root VAULT_TOKEN on this
// exec. Fail-soft: if VAULT_TOKEN is unset or OpenBao is unreachable, the write
// is skipped with a warning — the file remains the fallback and bootstrap does
// not fail the bring-up over it.
const VAULT_ADDR  = process.env.VAULT_ADDR || 'http://openbao:8200';
const VAULT_TOKEN = process.env.VAULT_TOKEN || '';

// Re-require a /config module after its file has been rewritten on disk
// (require caches the old contents otherwise).
function freshRequire(p) {
	delete require.cache[require.resolve(p)];
	return require(p);
}

// PUT (replace) the data at secret/data/<vaultPath> with `data`. Warn-only.
async function baoPut(vaultPath, data) {
	if (!VAULT_TOKEN) { log('OpenBao: VAULT_TOKEN unset — skipping write of secret/' + vaultPath); return; }
	try {
		const res = await fetch(`${VAULT_ADDR}/v1/secret/data/${vaultPath}`, {
			method: 'POST',
			headers: { 'X-Vault-Token': VAULT_TOKEN, 'Content-Type': 'application/json' },
			body: JSON.stringify({ data }),
		});
		if (!res.ok) {
			const text = await res.text().catch(() => '');
			log(`WARNING: OpenBao write secret/${vaultPath} failed (${res.status}) ${text} — app will use its file fallback`);
		} else {
			log(`OpenBao: wrote secret/${vaultPath}`);
		}
	} catch (e) {
		log(`WARNING: OpenBao write secret/${vaultPath} threw (${e.message}) — app will use its file fallback`);
	}
}

// Replicate the SSO's hashPasswordSSHA512 (models/user_ldap.js) exactly so the
// directory stores passwords the SSO can verify on bind (pw-sha2 module).
function hashPasswordSSHA512(password) {
	const salt = crypto.randomBytes(8);
	const hash = crypto.createHash('sha512').update(password).update(salt).digest();
	return '{SSHA512}' + Buffer.concat([hash, salt]).toString('base64');
}

// Run an openldap client binary; returns {code, stdout, stderr}. Does not throw
// on non-zero (ldapsearch exits 32 for "no such object", which we branch on).
function ldap(bin, args, ldif) {
	try {
		const stdout = execFileSync(bin, args, {
			input: ldif ? Buffer.from(ldif) : undefined,
			encoding: 'utf8',
			stdio: ['pipe', 'pipe', 'pipe'],
			env: { ...process.env, LDAPTLS_REQCERT: 'never' },
		});
		return { code: 0, stdout, stderr: '' };
	} catch (e) {
		return { code: e.status || 1, stdout: (e.stdout || '').toString(), stderr: (e.stderr || '').toString() };
	}
}

const bindArgs = (extra) => ['-x', '-H', LDAP_URL, '-D', BIND_DN, '-w', ADMIN_PASS, ...(extra || [])];

function entryExists(dn) {
	const r = ldap('ldapsearch', bindArgs(['-b', dn, '-s', 'base', '(objectClass=*)', 'dn']));
	return r.code === 0;
}

function ldapAdd(ldif) {
	return ldap('ldapadd', bindArgs(), ldif);
}

function ldapModify(ldif) {
	return ldap('ldapmodify', bindArgs(), ldif);
}

// ── 1. LDAP service account for the proxy ───────────────────────────────────
// The proxy / ldap-client bind as cn=ldapclient. For it to SHOW in the SSO Users
// UI as a service account it must (a) match the user filter (posixAccount) and
// (b) be a member of app_sso_service_account (that membership is what the Users
// page marks as a non-person/service account). Older bootstraps created it as a
// bare organizationalRole (invisible to the Users list) and never joined the
// group, so it never appeared. Both are fixed here; the existing-path shape add
// is best-effort so a pre-existing account still binds even if the upgrade add
// fails.
function ensureServiceAccount() {
	const pw = hashPasswordSSHA512(SVC_PASS);
	const uidNum = '10001'; // distinct from the bootstrap admin's 10000; above uidGidReservedFloor so regular-user id allocation ignores it
	if (entryExists(SVC_DN)) {
		log(`Service account ${SVC_DN} exists — ensuring service-account shape + password`);
		// Add the auxiliary posixAccount objectClass + required attrs so the entry
		// matches the Users list filter. inetOrgPerson is deliberately NOT added:
		// it is structural and would conflict with the existing organizationalRole.
		const shape = [
			`dn: ${SVC_DN}`,
			'changetype: modify',
			'add: objectClass',
			'objectClass: posixAccount',
			'-',
			'add: uid',
			'uid: ldapclient',
			'-',
			'add: uidNumber',
			`uidNumber: ${uidNum}`,
			'-',
			'add: gidNumber',
			`gidNumber: ${uidNum}`,
			'-',
			'add: homeDirectory',
			'homeDirectory: /nonexistent',
			'-',
			'add: description',
			'description: LDAP bind service account (proxy / ldap-client)',
			'',
		].join('\n');
		const rs = ldapModify(shape);
		if (rs.code !== 0 && !/already exists|Type or value exists/i.test(rs.stderr)) {
			log('  service-account shape warning (account still binds):', rs.stderr.trim());
		}
		const rp = ldapModify([
			`dn: ${SVC_DN}`,
			'changetype: modify',
			'replace: userPassword',
			`userPassword: ${pw}`,
			'',
		].join('\n'));
		if (rp.code !== 0) log('  password reset warning:', rp.stderr.trim());
	} else {
		log(`Creating service account ${SVC_DN}`);
		const entry = [
			`dn: ${SVC_DN}`,
			'objectClass: inetOrgPerson',
			'objectClass: posixAccount',
			'objectClass: top',
			'cn: ldapclient',
			'sn: ldapclient',
			'uid: ldapclient',
			`uidNumber: ${uidNum}`,
			`gidNumber: ${uidNum}`,
			'homeDirectory: /nonexistent',
			'description: LDAP bind service account (proxy / ldap-client)',
			`userPassword: ${pw}`,
			'',
		].join('\n');
		const r = ldapAdd(entry);
		if (r.code !== 0) throw new Error(`ldapadd service account failed: ${r.stderr.trim()}`);
	}
	// Mark it as a service account (the Users UI's service-account signal).
	const gdn = `cn=app_sso_service_account,ou=groups,${BASE_DN}`;
	const rm = ldapModify([
		`dn: ${gdn}`,
		'changetype: modify',
		'add: member',
		`member: ${SVC_DN}`,
		'',
	].join('\n'));
	if (rm.code === 0) log(`  marked ${SVC_DN} as a service account`);
	else if (/already exists|Type or value exists/i.test(rm.stderr)) log(`  ${SVC_DN} already in app_sso_service_account`);
	else log(`  app_sso_service_account membership warning:`, rm.stderr.trim());
}

// ── 2. First admin user ─────────────────────────────────────────────────────
function ensureAdmin() {
	const pw = hashPasswordSSHA512(ADMIN_USER_PASS);
	if (entryExists(ADMIN_DN)) {
		log(`Admin ${ADMIN_DN} exists — resetting password to ./config and ensuring groups`);
		ldapModify([
			`dn: ${ADMIN_DN}`,
			'changetype: modify',
			'replace: userPassword',
			`userPassword: ${pw}`,
			'',
		].join('\n'));
	} else {
		log(`Creating admin ${ADMIN_DN}`);
		const entry = [
			`dn: ${ADMIN_DN}`,
			'objectClass: inetOrgPerson',
			'objectClass: posixAccount',
			'objectClass: top',
			`cn: ${ADMIN_UID}`,
			`sn: Admin`,
			`uid: ${ADMIN_UID}`,
			'uidNumber: 10000',
			'gidNumber: 10000',
			`homeDirectory: /home/${ADMIN_UID}`,
			`userPassword: ${pw}`,
		];
		if (ADMIN_EMAIL) entry.push(`mail: ${ADMIN_EMAIL}`);
		entry.push('');
		const r = ldapAdd(entry.join('\n'));
		if (r.code !== 0) throw new Error(`ldapadd admin failed: ${r.stderr.trim()}`);
	}
	// Ensure group membership (idempotent — ignore "value already exists").
	for (const g of ADMIN_GROUPS) {
		const groupDn = `cn=${g},ou=groups,${BASE_DN}`;
		const r = ldapModify([
			`dn: ${groupDn}`,
			'changetype: modify',
			'add: member',
			`member: ${ADMIN_DN}`,
			'',
		].join('\n'));
		if (r.code === 0) log(`  added ${ADMIN_UID} to ${g}`);
		else if (/already exists|Type or value exists/i.test(r.stderr)) log(`  already in ${g}`);
		else log(`  group ${g} warning:`, r.stderr.trim());
	}
}

// ── 3. Login as the admin (validates the password) ──────────────────────────
async function login() {
	const res = await fetch(`${SSO_INTERNAL}/api/auth/login`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ uid: ADMIN_UID, password: ADMIN_USER_PASS }),
	});
	if (!res.ok) {
		const text = await res.text().catch(() => '');
		throw new Error(`admin login failed (${res.status}): ${text}`);
	}
	const data = await res.json();
	if (!data.token) throw new Error(`admin login returned no token: ${JSON.stringify(data)}`);
	log(`Logged in as ${ADMIN_UID}`);
	return data.token;
}

// ── 4. OAuth client for the proxy ───────────────────────────────────────────
async function listClients(token) {
	const res = await fetch(`${SSO_INTERNAL}/api/oauth/client`, {
		headers: { 'auth-token': token },
	});
	if (!res.ok) throw new Error(`list OAuth clients failed (${res.status})`);
	const data = await res.json();
	return (data && data.results) || [];
}

async function createClient(token, opts) {
	const o = opts || { name: CLIENT_NAME, description: 'theta-suite proxy (auto-registered)', redirect_uris: proxyRedirectUris() };
	const res = await fetch(`${SSO_INTERNAL}/api/oauth/client`, {
		method: 'POST',
		headers: { 'auth-token': token, 'Content-Type': 'application/json' },
		body: JSON.stringify({
			name: o.name,
			description: o.description,
			redirect_uris: o.redirect_uris,
			scopes: ['openid', 'profile', 'email', 'groups'],
			allowed_groups: [],
		}),
	});
	if (!res.ok) {
		const text = await res.text().catch(() => '');
		throw new Error(`create OAuth client failed (${res.status}): ${text}`);
	}
	const data = await res.json();
	const id = (data.results && data.results.client_id) || data.client_id;
	const secret = data.client_secret;
	if (!id || !secret) throw new Error(`create OAuth client returned no id/secret: ${JSON.stringify(data)}`);
	log(`Created OAuth client ${o.name} (${id})`);
	return { id, secret };
}

// Add any redirect_uris the client is missing, keeping whatever the operator
// has already registered. Backfills installs whose proxy client was created
// before the per-host `__proxy_auth/callback` patterns existed — without this,
// setting a host's auth to SSO fails with "400 redirect_uri is not registered
// for this client" on an upgraded stack and only works on a fresh one.
// Warn-only: a stack that cannot widen its client is still a working stack.
async function ensureRedirectUris(token, client, wanted) {
	const have = client.redirect_uris || [];
	const missing = wanted.filter((u) => !have.includes(u));
	if (!missing.length) return;
	try {
		const res = await fetch(`${SSO_INTERNAL}/api/oauth/client/${client.client_id}`, {
			method: 'PUT',
			headers: { 'auth-token': token, 'Content-Type': 'application/json' },
			body: JSON.stringify({ redirect_uris: [...have, ...missing] }),
		});
		if (!res.ok) throw new Error(`${res.status} ${await res.text().catch(() => '')}`);
		log(`  OAuth client ${client.name}: registered ${missing.length} redirect URI(s) for per-host SSO`);
	} catch (error) {
		log(`  WARNING: could not add redirect URIs to ${client.name}: ${error.message}`);
	}
}

async function rotateClient(token, id) {
	const res = await fetch(`${SSO_INTERNAL}/api/oauth/client/${id}/rotate`, {
		method: 'POST',
		headers: { 'auth-token': token },
	});
	if (!res.ok) {
		const text = await res.text().catch(() => '');
		throw new Error(`rotate OAuth client failed (${res.status}): ${text}`);
	}
	const data = await res.json();
	if (!data.client_secret) throw new Error(`rotate returned no secret: ${JSON.stringify(data)}`);
	log(`Rotated secret for OAuth client ${id}`);
	return { id, secret: data.client_secret };
}

// ── 5. Seed the SSO directory with the stack's own resources ────────────────
// The Directory page (site → host → service hierarchy) starts empty even
// though this stack knows exactly what it deployed. Seed it: one site (the
// domain), one host (the box this stack runs on), and the two services
// (SSO Manager + proxy), then link the proxy's OAuth client under its
// service. Idempotent — existing slugs are left untouched, so operator
// edits (renames, metadata, extra resources) survive re-runs. Failures
// here only warn: the directory is a nicety, never worth failing a
// bring-up over (e.g. an older sso-manager image without /api/directory).
const DOMAIN = (sso.stack && sso.stack.ldapDomain) || '';
const ORG    = sso.name || 'SSO Manager';

const slugify = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

async function dirGet(token, path) {
	const res = await fetch(`${SSO_INTERNAL}/api/directory-admin/${path}`, {
		headers: { 'auth-token': token },
	});
	if (!res.ok) throw new Error(`GET /api/directory-admin/${path} failed (${res.status})`);
	return res.json();
}

async function dirPost(token, path, body) {
	const res = await fetch(`${SSO_INTERNAL}/api/directory-admin/${path}`, {
		method: 'POST',
		headers: { 'auth-token': token, 'Content-Type': 'application/json' },
		body: JSON.stringify(body),
	});
	if (!res.ok) {
		const text = await res.text().catch(() => '');
		throw new Error(`POST /api/directory-admin/${path} failed (${res.status}): ${text}`);
	}
	return res.json();
}

async function dirPut(token, path, body) {
	const res = await fetch(`${SSO_INTERNAL}/api/directory-admin/${path}`, {
		method: 'PUT',
		headers: { 'auth-token': token, 'Content-Type': 'application/json' },
		body: JSON.stringify(body),
	});
	if (!res.ok) {
		const text = await res.text().catch(() => '');
		throw new Error(`PUT /api/directory-admin/${path} failed (${res.status}): ${text}`);
	}
	return res.json();
}

async function dirDelete(token, path) {
	const res = await fetch(`${SSO_INTERNAL}/api/directory-admin/${path}`, {
		method: 'DELETE',
		headers: { 'auth-token': token },
	});
	if (!res.ok) {
		const text = await res.text().catch(() => '');
		throw new Error(`DELETE /api/directory-admin/${path} failed (${res.status}): ${text}`);
	}
	return res.json();
}

// The site the stack registers itself under. Also the default "Location
// (Site)" that ldap-client-joined Linux hosts attach to (parent slug
// site_<name> — see ldap-client/index.sh), so the slugs must line up.
const SITE_NAME = (sso.stack && sso.stack.siteName) || 'local';

// Host facts, collected by setup.sh ON THE HOST (inside this container
// hostname/uname describe the container) and passed via the exec env. Same
// fields ldap-client/index.sh registers, so stack hosts and ldap-client-
// joined hosts carry identical metadata.
const HOST_FACTS = {
	name:   process.env.STACK_HOST_NAME   || '',
	ip:     process.env.STACK_HOST_IP     || '',
	mac:    process.env.STACK_HOST_MAC    || '',
	os:     process.env.STACK_HOST_OS     || '',
	kernel: process.env.STACK_HOST_KERNEL || '',
};

async function seedDirectory(token, clientId, jumpClientId) {
	let resources = ((await dirGet(token, 'resources')).results) || [];
	// Tolerated separately from the resource list: edges only drive the
	// re-parent + OAuth-link steps, and losing those is not a reason to skip
	// seeding the resources themselves.
	let edges = [];
	try { edges = ((await dirGet(token, 'edges')).results) || []; }
	catch (e) { log(`  WARNING: could not list directory edges (${e.message}) — skipping re-parent/link steps`); }

	// Move an already-seeded resource under the parent it should have had.
	// Only ever corrects a parent this bootstrap itself seeded wrongly (the
	// proxy/jump services were parented to the stack host instead of to
	// host_theta-proxy / host_theta-jump); an operator who has deliberately
	// re-parented something keeps their layout, because we only rewire when the
	// current parent is the one the old code would have set.
	async function reparent(resource, wantParentId, fromParentId) {
		if (!resource || !wantParentId || !fromParentId) return;
		const current = edges.find((e) => e.childId === resource.id && (e.relation === 'hosts' || e.relation === 'oauth'));
		if (!current) return;                          // unparented: leave it alone
		if (current.parentId === wantParentId) return; // already correct
		if (current.parentId !== fromParentId) return; // operator moved it: respect that
		// PUT with kind + hostId is what makes the route rewire the parent edge.
		await dirPut(token, `resources/${resource.id}`, { kind: resource.kind, hostId: wantParentId });
		current.parentId = wantParentId;
		log(`  directory: re-parented ${resource.kind} '${resource.slug}' onto its own host`);
	}

	// Create a resource unless its slug (or a legacy alternate from an earlier
	// seed layout) already exists. On an existing resource, seed metadata keys
	// it doesn't have yet are filled in — operator-set values always win and
	// are never overwritten.
	async function ensure(kind, name, slug, parentId, metadata, altSlugs) {
		const slugs = [slug, ...(altSlugs || [])];
		const found = resources.find((r) => slugs.includes(r.slug));
		if (found) {
			const have = found.metadata || {};
			const missing = Object.entries(metadata || {})
				.filter(([k, v]) => (have[k] === undefined || have[k] === '') && v !== '');
			if (missing.length) {
				const merged = { ...have };
				for (const [k, v] of missing) merged[k] = v;
				// metadata-only PUT: no kind/hostId in the body, so the route's
				// parent validation and edge rewiring are not triggered.
				await dirPut(token, `resources/${found.id}`, { metadata: merged });
				found.metadata = merged;
				log(`  directory: ${kind} '${found.slug}' exists — filled ${missing.map(([k]) => k).join(', ')}`);
			} else {
				log(`  directory: ${kind} '${found.slug}' exists — keeping`);
			}
			return found;
		}
		const body = { kind, name, slug, metadata: metadata || {} };
		if (parentId) body.hostId = parentId; // POST creates the parent edge
		const created = (await dirPost(token, 'resources', body)).results;
		resources.push(created);
		log(`  directory: created ${kind} '${slug}'`);
		return created;
	}

	// site_<name> / host_<name> slug convention matches ldap-client/index.sh.
	// altSlugs grandfather in the layout the first seed release used.
	const site = await ensure('site', SITE_NAME, `site_${slugify(SITE_NAME)}`, null,
		{ isCurrentSite: true },
		[slugify(DOMAIN || ORG)]);
	const hostSlug = HOST_FACTS.name ? `host_${slugify(HOST_FACTS.name)}` : 'stack-host';
	const host = await ensure('host', HOST_FACTS.name || 'Stack host', hostSlug, site.id, {
		subType: 'linux',
		ip: HOST_FACTS.ip,
		address: HOST_FACTS.ip,
		macAddress: HOST_FACTS.mac,
		os: HOST_FACTS.os,
		kernel: HOST_FACTS.kernel,
		sshPort: 22,
		managed: true,
	}, ['stack-host']);

	// "Host" means a real, independently-existing machine — something with its
	// own OS and sshd, that theta-agent or a directory-aware tool like the jump
	// host could actually reach on its own. A Docker container backing one of
	// this stack's own services is never that, no matter how convenient it'd be
	// to group its services under a host-shaped node in the UI: it has no sshd,
	// no independent network identity, nothing jump-host could honestly offer
	// as an SSH target. Proxy and jump-host are two of this stack's five
	// containers, running on the one real host above (`host`) — not machines of
	// their own. Briefly (2026-08-05 through the next release) this file seeded
	// `host_theta-proxy` / `host_theta-jump` as first-class `kind: 'host'`
	// resources to fix their services being parented to the stack host; that
	// solved the parenting problem with the wrong tool. The right tool already
	// existed: `kind: 'container'` (see seedPlugins' Docker discovery, which
	// already attaches `docker-theta-suite-proxy` etc. under these services
	// correctly) sits one layer below `service`, same as `sso-manager` and
	// `openbao` already do. So: no synthetic hosts — Proxy's and jump-host's
	// services parent directly onto the stack host, same as everything else.

	await ensure('service', 'SSO Manager', 'sso-manager', host.id, {
		address: `https://${SSO_HOST}`,
		port: 3001,
		gitRepo: 'https://github.com/theta42/sso-manager-node',
		subType: 'web',
		icon: 'mdi:shield-account',
		tagline: 'Home-lab identity and access management.',
		requestable: false,
	});
	// Proxy = the node management UI; OpenResty = the data plane every hostname
	// in the stack actually flows through (80/443). Two faces, two entries, both
	// parented directly to the stack host — see the "Host means..." note above.
	const psvc = await ensure('service', 'Proxy', 'proxy', host.id, {
		address: `https://${PROXY_HOST}`,
		port: 3000,
		gitRepo: 'https://github.com/theta42/proxy',
		subType: 'web',
		icon: 'mdi:server-network',
		tagline: 'Reverse proxy and API gateway.',
		requestable: false,
	});
	// OpenLDAP is independently consumed — Linux hosts authenticate against it
	// (PAM/SSSD, sudoRole, sshPublicKey) and LDAP-native apps bind directly
	// (see the SSO's /integrations page) — so it gets its own entry. Advertise
	// the operator-configured LDAPS hostname when set, else the SSO host.
	// The bundled slapd's image/config live in sso-manager-node.
	const LDAPS_HOST = (sso.ldap && sso.ldap.ldapsHost) || SSO_HOST;
	await ensure('service', 'OpenLDAP Directory', 'openldap', host.id, {
		address: `ldaps://${LDAPS_HOST}:636`,
		port: 389,
		externalPort: 636,
		portMappings: [{ proto: 'tcp', external: 636, internal: 389, comment: 'LDAPS' }],
		gitRepo: 'https://github.com/theta42/sso-manager-node',
		subType: 'openldap',
		icon: 'mdi:book-open-outline',
		tagline: 'LDAP directory for identity.',
		requestable: false,
	});
	// Wildcard address: OpenResty fronts every host under the domain (same
	// */** wildcard convention the proxy's Host records use). Its config lives
	// in the proxy repo (ops/nginx_conf).
	await ensure('service', 'OpenResty Edge', 'openresty', host.id, {
		address: DOMAIN ? `https://*.${DOMAIN}` : `https://${PROXY_HOST}`,
		port: 443,
		gitRepo: 'https://github.com/theta42/proxy',
		subType: 'openresty',
		icon: 'mdi:router-network',
		tagline: 'Data plane.',
		requestable: false,
	});

	// OpenBao and its renewer sidecar are part of what the stack deploys, so
	// they belong in the directory like every other component. Without entries
	// their containers had nowhere to attach and showed up as parentless
	// discoveries on a fresh install.
	await ensure('service', 'OpenBao', 'openbao', host.id, {
		address: 'http://openbao:8200',
		port: 8200,
		subType: 'vault',
		icon: 'mdi:safe',
		tagline: 'Secrets store for the stack.',
		requestable: false,
	});
	await ensure('service', 'Bao Renewer', 'bao-renewer', host.id, {
		subType: 'sidecar',
		icon: 'mdi:autorenew',
		tagline: 'Renews the stack service tokens against OpenBao.',
		requestable: false,
	});

	// SSH jump host service (core component — always registered).
	let jumpSvc = null;
	{
		const jumpHost = process.env.CFG_JUMP_HOST || (DOMAIN ? `jump.${DOMAIN}` : '');
		jumpSvc = await ensure('service', 'SSH Jump Host', 'jump-host', host.id, {
			address: jumpHost ? `https://${jumpHost}` : '',
			port: 3002,
			gitRepo: 'https://github.com/theta42/jump-host',
			subType: 'ssh',
			icon: 'mdi:ssh',
			tagline: 'Secure SSH jump host.',
			requestable: false,
		});
	}

	// Correct installs seeded between 2026-08-05 and this release, where Proxy's
	// and jump-host's services were parented to now-removed synthetic
	// `host_theta-proxy` / `host_theta-jump` resources instead of the stack
	// host. Look them up by slug (never created going forward) rather than
	// `ensure`-ing them back into existence: on any install that never had
	// them, or already got corrected, this is a no-op.
	const proxyHostRes = resources.find((r) => r.slug === 'host_theta-proxy');
	const jumpHostRes = resources.find((r) => r.slug === 'host_theta-jump');
	if (proxyHostRes) {
		await reparent(psvc, host.id, proxyHostRes.id);
		await reparent(resources.find((r) => r.slug === 'openresty'), host.id, proxyHostRes.id);
	}
	if (jumpHostRes) {
		await reparent(jumpSvc, host.id, jumpHostRes.id);
	}

	// Once childless, the synthetic host itself is dead weight from this file's
	// own earlier mistake — never something an operator would hand-create at
	// these exact reserved slugs — so remove it. DELETE /resources/:id clears
	// its own edges first, so this is safe now that the reparents above have
	// already moved the real children off of it.
	async function removeIfChildless(resource, label) {
		if (!resource) return;
		const stillHasChildren = edges.some((e) => e.parentId === resource.id);
		if (stillHasChildren) {
			log(`  directory: '${label}' still has children after reparenting — leaving it for now`);
			return;
		}
		await dirDelete(token, `resources/${resource.id}`);
		log(`  directory: removed now-empty synthetic host '${label}'`);
	}
	await removeIfChildless(proxyHostRes, 'host_theta-proxy');
	await removeIfChildless(jumpHostRes, 'host_theta-jump');

	// Link an OAuth client (Resource-backed since sso-manager 1.3.0) under its
	// owning service, if it appears in the directory and isn't linked yet.
	async function linkOauthClient(id, parent, label) {
		if (!id || !parent) return;
		const oauthRes = resources.find((r) => r.id === id);
		if (!oauthRes) return;
		const linked = edges.some((e) => e.childId === id);
		if (!linked) {
			await dirPost(token, 'edges', { parentId: parent.id, childId: id, relation: 'oauth' });
			edges.push({ parentId: parent.id, childId: id, relation: 'oauth' });
			log(`  directory: linked OAuth client under '${label}'`);
		}
	}
	await linkOauthClient(clientId, psvc, 'proxy');
	await linkOauthClient(jumpClientId, jumpSvc, 'jump-host');
}

// ── Plugin instances ────────────────────────────────────────────────────────
// Seed a sensible default set of plugin instances so the stack is usable the
// moment it boots, without the operator having to add them by hand. The setup
// stack runs on Docker, so the single biggest win is a Docker discovery plugin
// pointed at the local daemon socket: containers that make up the stack (and
// any others on the host) get discovered into the Directory automatically.
// Idempotent per slug: an instance an operator already created is left alone.
async function seedPlugins(token) {
	async function pluginGet(path) {
		const res = await fetch(`${SSO_INTERNAL}/api/plugins/${path}`, {
			headers: { 'auth-token': token },
		});
		if (!res.ok) throw new Error(`GET /api/plugins/${path} failed (${res.status})`);
		return res.json();
	}
	async function pluginPost(body) {
		const res = await fetch(`${SSO_INTERNAL}/api/plugins/`, {
			method: 'POST',
			headers: { 'auth-token': token, 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		});
		if (!res.ok) {
			const text = await res.text().catch(() => '');
			throw new Error(`POST /api/plugins failed (${res.status}): ${text}`);
		}
		return res.json();
	}

	async function ensurePlugin({ pluginType, name, slug, config }) {
		const existing = ((await pluginGet('')).results) || [];
		if (existing.some((i) => i.slug === slug)) {
			log(`  plugins: '${slug}' exists — keeping`);
			return;
		}
		await pluginPost({ pluginType, name, slug, config });
		log(`  plugins: created '${slug}' (${pluginType})`);
	}

	try {
		// The Docker daemon the setup stack itself runs under. The socket must be
		// mounted into the sso container for discovery to reach it; if it isn't,
		// discovery simply errors non-fatally until it is.
		await ensurePlugin({
			pluginType: 'docker',
			name: 'Local Docker daemon',
			slug: 'docker-local',
			config: {
				socketPath: '/var/run/docker.sock',
				// Containers in our own compose project are the stack itself --
				// already seeded as services above. Telling the plugin which
				// project that is lets it mark them managed and attach them to
				// the service they implement, instead of a fresh install
				// presenting its own five containers as unmanaged discoveries.
				stackProject: process.env.COMPOSE_PROJECT_NAME || 'theta-suite',
				hostSlug: HOST_FACTS.name ? `host_${slugify(HOST_FACTS.name)}` : '',
			},
		});
	} catch (e) {
		log(`WARNING: plugin seed failed (${e.message || e}) — continuing`);
	}
}

// Write the OAuth client creds back into /config/proxy-secrets.js so the proxy
// (which reads that file) can use them. Only the clientId/clientSecret lines
// are touched; the rest of the file (operator edits, comments) is preserved.
// Handles single- or double-quoted values. Creds are UUIDs — no quotes in them.
function writeProxyCreds(id, secret) {
	const path = '/config/proxy-secrets.js';
	let src;
	try {
		src = fs.readFileSync(path, 'utf8');
	} catch (e) {
		log(`WARNING: cannot read ${path} to write creds back (${e.message}) — update proxy-secrets.js manually with clientId=${id}`);
		return false;
	}
	const before = src;
	src = src.replace(/(clientId:\s*)(['"])[^'"]*\2/, `$1$2${id}$2`);
	src = src.replace(/(clientSecret:\s*)(['"])[^'"]*\2/, `$1$2${secret}$2`);
	if (src === before) {
		log(`WARNING: could not locate clientId/clientSecret in ${path} — update it manually with clientId=${id} clientSecret=${secret}`);
		return false;
	}
	try {
		fs.writeFileSync(path, src);
		log(`Wrote OAuth client creds into ${path}`);
		return true;
	} catch (e) {
		log(`WARNING: cannot write ${path} (${e.message}) — is ./config mounted read-write on sso-manager? Update proxy-secrets.js manually with clientId=${id} clientSecret=${secret}`);
		return false;
	}
}

// The proxy needs a read-only SSO API token so its per-host SSO allow-list can
// suggest the directory's actual groups (otherwise the "Allowed groups" field
// autocompletes from the proxy's local groups only, which for an SSO-gated host
// is never what the operator wants). Idempotent: only mints when the file's
// `sso.apiToken` is still empty, and only rewrites that one line. Warn-only —
// no token just means no suggestions.
const PROXY_TOKEN_NAME = 'theta-proxy';

async function ensureProxyApiToken(token) {
	const path = '/config/proxy-secrets.js';
	let src;
	try {
		src = fs.readFileSync(path, 'utf8');
	} catch (e) {
		log(`  WARNING: cannot read ${path} to add an SSO API token (${e.message})`);
		return;
	}
	// An `sso: { ... apiToken: 'sso_...' }` already present means we're done.
	if (/apiToken:\s*['"]sso_[0-9a-f]{24}_[0-9a-f]{48}['"]/.test(src)) {
		log('  proxy already has an SSO API token — keeping');
		return;
	}
	if (!/\bsso:\s*\{/.test(src)) {
		log(`  WARNING: ${path} has no \`sso\` block — add one with url + apiToken to enable SSO group autocomplete`);
		return;
	}
	try {
		const apiToken = await mintApiToken(token, PROXY_TOKEN_NAME, 'theta-suite proxy (auto-registered)');
		// Replace the apiToken line inside the sso block only. The jump host's
		// token lives in a different file, so an unanchored match is safe here.
		const updated = src.replace(/(apiToken:\s*)(['"])[^'"]*\2/, `$1$2${apiToken}$2`);
		if (updated === src) {
			log(`  WARNING: could not locate apiToken in ${path} — set sso.apiToken manually`);
			return;
		}
		fs.writeFileSync(path, updated);
		log(`  Minted SSO API token for the proxy and wrote it into ${path}`);
	} catch (e) {
		log(`  WARNING: could not provision the proxy's SSO API token: ${e.message}`);
	}
}

// Mint (or reuse) a theta-agent join key and hand it to setup.sh.
//
// A join key is the single credential an operator needs to add a host: the
// agent presents it, the SSO enrolls the host and issues it its own per-agent
// token + public key, which the agent writes back into its agent.yml. Without
// this, adding a host meant pre-registering it in the SSO and copying two
// values onto the machine by hand -- and setup.sh's own agent install had no
// way to produce a token the server would accept at all.
//
// Idempotent: reuses the existing `setup` key rather than piling up new ones.
// A key can only be shown once, so if the stored one is not recoverable we mint
// a replacement and label it for the run that created it.
async function ensureAgentJoinKey(token) {
	try {
		const res = await fetch(`${SSO_INTERNAL}/api/agent/join-keys`, {
			method: 'POST',
			headers: { 'auth-token': token, 'Content-Type': 'application/json' },
			body: JSON.stringify({ label: 'setup' }),
		});
		if (!res.ok) throw new Error(`${res.status} ${await res.text().catch(() => '')}`);
		const data = await res.json();
		if (!data.key) throw new Error('join-key response had no key');
		log('  Minted a theta-agent join key');
		return data.key;
	} catch (error) {
		log(`  WARNING: could not mint a theta-agent join key: ${error.message}`);
		return '';
	}
}

// ── 6. Provision the SSH jump host ─────────────────────────────────────────
// The jump host is a core component (always provisioned). It needs: a directory
// API token (to resolve which hosts a user may reach), an LDAP bind account
// that can WRITE the sshPublicKey attribute (it injects its own key on first
// use), and a config file it reads. We write /config/jump-secrets.js deriving
// LDAP/site from sso-secrets.js + a freshly minted API token. The bundled jump
// host binds as cn=admin (already able to write sshPublicKey) — hardened
// bare-metal deployments should use a scoped account + attribute ACL instead
// (see the jump-host README). Idempotent: skips if the file already has a real
// token.
const JUMP_HOST = process.env.CFG_JUMP_HOST || (DOMAIN ? `jump.${DOMAIN}` : '');
const JUMP_SECRETS = '/config/jump-secrets.js';
const JUMP_TOKEN_NAME = 'theta-jump-host';
const JUMP_CLIENT_NAME = 'theta-jump';
const JUMP_REDIRECT_URI = `https://${JUMP_HOST}/api/auth/oidc/callback`;

async function mintApiToken(token, name, description) {
	const res = await fetch(`${SSO_INTERNAL}/api/api-token`, {
		method: 'POST',
		headers: { 'auth-token': token, 'Content-Type': 'application/json' },
		body: JSON.stringify({ name, description: description || 'theta-suite jump host (auto-registered)' }),
	});
	if (!res.ok) throw new Error(`mint API token failed (${res.status}): ${await res.text().catch(() => '')}`);
	const data = await res.json();
	const raw = data.token || (data.results && data.results.token) || data.raw_token;
	if (!raw) throw new Error(`API token response had no token: ${JSON.stringify(data)}`);
	return raw;
}

// The generated file is "complete" only if it has BOTH a real directory API
// token AND an OIDC client id — an existing file from the pre-OIDC layout (a
// token but no oidc block) is regenerated so the web UI's SSO login works.
function jumpFileComplete() {
	try {
		const src = fs.readFileSync(JUMP_SECRETS, 'utf8');
		const hasToken = /apiToken:\s*['"]sso_[0-9a-f]{24}_[0-9a-f]{48}['"]/.test(src);
		const hasOidc = /clientId:\s*['"][0-9a-f-]{8,}['"]/.test(src);
		return hasToken && hasOidc;
	} catch (_) { return false; }
}

function writeJumpSecrets(apiToken, oidc, localAdminPass) {
	const siteName = (sso.stack && sso.stack.siteName) || 'local';
	const ldapsHost = (sso.ldap && sso.ldap.ldapsHost) || SSO_HOST;
	const body = `'use strict';
// Generated by theta-suite bootstrap. The jump host reads this via
// @simpleworkjs/conf (CONF_SECRETS). Binds as cn=admin so it can write the
// sshPublicKey attribute (key injection); for a hardened deployment use a
// scoped account with an sshPublicKey write-ACL instead (see jump-host README).
module.exports = {
\tldap: {
\t\t// ldaps:// (636), not ldap:// (389): @simpleworkjs/ldap's client always
\t\t// sets tlsOptions (see jump-host's models/user_ldap.js), and ldapts
\t\t// treats a non-empty tlsOptions as "use implicit TLS" regardless of the
\t\t// URL scheme -- pointed at the plain port, that means it opens a raw TLS
\t\t// handshake against a server expecting plaintext LDAP, which slapd just
\t\t// drops (logged as "connection lost", no BIND ever attempted). This bit
\t\t// jump-host silently: every SSH login failed with the generic
\t\t// "Permission denied" for any password, because getUser()/checkPassword()
\t\t// never even reached slapd.
\t\turl: 'ldaps://sso-manager:636',
\t\tbindDN: ${JSON.stringify(BIND_DN)},
\t\tbindPassword: ${JSON.stringify(ADMIN_PASS)},
\t\tuserBase: ${JSON.stringify(`ou=people,${BASE_DN}`)},
\t\tgroupBase: ${JSON.stringify(`ou=groups,${BASE_DN}`)},
\t\ttlsOptions: { rejectUnauthorized: false },
\t},
\tsso: {
\t\turl: 'http://sso-manager:3001',
\t\tapiToken: ${JSON.stringify(apiToken)},
\t},
\tssh: {
\t\tlistenPort: 2222,
\t\thostKeyPath: '/var/lib/jump-host/keys',
\t\tpasswordAuth: 'off',
\t\tkeyComment: ${JSON.stringify(`jump-host@${siteName}`)},
\t},
\tweb: { port: 3002 },
\t// Web UI SSO login — the jump host's own OAuth client. tokenEndpoint /
\t// userinfoEndpoint use the internal docker-net address (server-to-server);
\t// authorizationEndpoint is the public SSO host (browser-facing).
\toidc: {
\t\tenabled: true,
\t\tissuer: ${JSON.stringify(`https://${SSO_HOST}`)},
\t\tauthorizationEndpoint: ${JSON.stringify(`https://${SSO_HOST}/oauth/authorize`)},
\t\ttokenEndpoint: 'http://sso-manager:3001/oauth/token',
\t\tuserinfoEndpoint: 'http://sso-manager:3001/oauth/userinfo',
\t\tclientId: ${JSON.stringify(oidc.id)},
\t\tclientSecret: ${JSON.stringify(oidc.secret)},
\t\tredirectUri: ${JSON.stringify(JUMP_REDIRECT_URI)},
\t\tscopes: ['openid', 'profile', 'email', 'groups'],
\t\tgroupsClaim: 'groups',
\t\tusernameClaim: 'preferred_username',
\t},
\tauth: {
\t\tadminGroups: ['app_sso_admin'],
\t\tadminUsers: ['jumpadmin'],
\t\tlocalAdminPass: ${JSON.stringify(localAdminPass)},
\t},
\tredis: { prefix: 'jump_host_', redisConf: { url: 'redis://127.0.0.1:6379' } },
\tstack: { ssoHost: ${JSON.stringify(SSO_HOST)}, jumpHost: ${JSON.stringify(JUMP_HOST)}, ldapsHost: ${JSON.stringify(ldapsHost)} },
};
`;
	fs.writeFileSync(JUMP_SECRETS, body, { mode: 0o600 });
}

// Returns the jump host's OAuth client id (so seedDirectory can link it under
// the SSH Jump Host service), whether or not this run actually wrote a fresh
// jump-secrets.js -- otherwise re-runs on an already-configured deployment
// never get a chance to self-heal a missing directory link (see the "no
// parent" bug this was written for).
async function provisionJumpHost(token) {
	if (jumpFileComplete()) {
		log('Jump host: /config/jump-secrets.js already has API token + OIDC client — keeping.');
		const clients = await listClients(token);
		const existing = clients.find((c) => c.name === JUMP_CLIENT_NAME);
		return existing ? existing.client_id : null;
	}
	const apiToken = await mintApiToken(token, JUMP_TOKEN_NAME);

	// Mint (or reuse) the jump host's own OAuth client for web-UI SSO login.
	const clients = await listClients(token);
	let oidc = clients.find((c) => c.name === JUMP_CLIENT_NAME);
	if (oidc && oidc.client_id) {
		oidc = await rotateClient(token, oidc.client_id);
		oidc = { id: oidc.id, secret: oidc.secret };
	} else {
		oidc = await createClient(token, {
			name: JUMP_CLIENT_NAME,
			description: 'theta-suite jump host web UI (auto-registered)',
			redirect_uris: [JUMP_REDIRECT_URI],
		});
	}

	const localAdminPass = crypto.randomBytes(16).toString('hex');
	writeJumpSecrets(apiToken, oidc, localAdminPass);
	log(`Jump host: wrote /config/jump-secrets.js (API token + OAuth client ${oidc.id}).`);
	log(`Jump host: local admin 'jumpadmin' password: ${localAdminPass}`);
	return oidc.id;
}

(async function main() {
	try {
		log(`Base DN: ${BASE_DN}`);
		ensureServiceAccount();
		ensureAdmin();
		const token = await login();

		const list = await listClients(token);
		// Find the proxy's client: by id if we have usable creds, else by name.
		let resolvedClientId = '';
		let client = null;
		if (HAS_USABLE_CREDS) client = list.find((c) => c.client_id === EXISTING_ID);
		if (!client) client = list.find((c) => c.name === CLIENT_NAME);

		// Widen an existing client before any of the branches below return: a
		// freshly created one already gets these from createClient().
		if (client) await ensureRedirectUris(token, client, proxyRedirectUris());

		if (client && HAS_USABLE_CREDS && client.client_id === EXISTING_ID) {
			// File creds match an existing client — trust the file's secret
			// (it's bcrypt-hashed server-side, so we can't verify, but the proxy
			// was working with it). Keep the file as-is.
			log(`OAuth client ${CLIENT_NAME} (${EXISTING_ID}) exists and proxy-secrets.js has its creds — keeping`);
			out('CLIENT_ID', EXISTING_ID);
			out('CLIENT_SECRET', EXISTING_SECRET);
			out('ALREADY_CONFIGURED', '1');
			resolvedClientId = EXISTING_ID;
		} else if (client) {
			// Client exists but the file has no recoverable secret for it — rotate
			// so the proxy gets a fresh secret it can actually read, then write back.
			log(`OAuth client ${CLIENT_NAME} (${client.client_id}) exists but proxy-secrets.js has no usable secret — rotating + writing back`);
			const { id, secret } = await rotateClient(token, client.client_id);
			writeProxyCreds(id, secret);
			out('CLIENT_ID', id);
			out('CLIENT_SECRET', secret);
			out('ALREADY_CONFIGURED', '0');
			resolvedClientId = id;
		} else {
			// No client yet — create one and write the generated creds back.
			const { id, secret } = await createClient(token);
			writeProxyCreds(id, secret);
			out('CLIENT_ID', id);
			out('CLIENT_SECRET', secret);
			out('ALREADY_CONFIGURED', '0');
			resolvedClientId = id;
		}

		// Must run before the baoPut below: that snapshots proxy-secrets.js into
		// OpenBao, and the proxy loads its conf from there at boot, so a token
		// written after the snapshot would never reach the running proxy.
		await ensureProxyApiToken(token);

		// Mirror the (now-current) proxy-secrets.js into OpenBao so the proxy
		// loads it from there at boot via @simpleworkjs/bao-conf. Re-require
		// fresh: writeProxyCreds rewrote the file out from under the cached
		// `proxy` object. setup.sh's seed already put a placeholder version
		// here; this replaces it with the complete file (operator edits +
		// generated OAuth creds). Warn-only.
		await baoPut('proxy/conf', freshRequire('/config/proxy-secrets.js'));

		// Provision the jump host (mint token + write config). Warn-only — never
		// fail the whole bring-up over it, but it's a core component so always
		// attempted (no longer gated by CFG_JUMP_HOST_ENABLED).
		let jumpClientId = null;
		try {
			jumpClientId = await provisionJumpHost(token);
			out('JUMP_HOST_CONFIGURED', '1');
			// Mirror jump-secrets.js (just written by provisionJumpHost) into
			// OpenBao so the jump host loads it from there at boot via
			// @simpleworkjs/bao-conf. setup.sh's seed may have put a
			// placeholder/stale version here; this replaces it with the
			// complete file (LDAP bind, minted API token, OAuth client).
			// Warn-only.
			await baoPut('jump-host/conf', freshRequire(JUMP_SECRETS));
		} catch (e) {
			log(`WARNING: jump host provisioning failed (${e.message || e}) — continuing`);
		}

		// The agent join key setup.sh writes into /etc/theta42/agent.yml.
		out('AGENT_JOIN_KEY', await ensureAgentJoinKey(token));

		// Seed the directory (site/host/services + OAuth client link). Never
		// fails the bootstrap — warn and continue.
		try {
			log('Seeding directory resources...');
			await seedDirectory(token, resolvedClientId, jumpClientId);
		} catch (e) {
			log(`WARNING: directory seed failed (${e.message || e}) — continuing`);
		}

		// Seed default plugin instances (Docker discovery) — same warn-and-go
		// policy; a stack without plugins is still usable.
		try {
			log('Seeding default plugins...');
			await seedPlugins(token);
		} catch (e) {
			log(`WARNING: plugin seed failed (${e.message || e}) — continuing`);
		}

		log('Done.');
		process.exit(0);
	} catch (e) {
		process.stderr.write(`[bootstrap] ERROR: ${e.message || e}\n`);
		process.exit(1);
	}
})();