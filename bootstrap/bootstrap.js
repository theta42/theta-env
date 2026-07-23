#!/usr/bin/env node
/*
 * theta-env bootstrap — runs inside the sso-manager container to wire the
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
const SSO_INTERNAL = 'http://localhost:3001';
const CLIENT_NAME = 'theta-proxy';

const ADMIN_DN  = `cn=${ADMIN_UID},ou=people,${BASE_DN}`;
const SVC_DN    = `cn=ldapclient,ou=people,${BASE_DN}`;
const ADMIN_GROUPS = ['app_sso_admin', 'app_sso_oauth_admin'];

const log  = (...a) => process.stderr.write('[bootstrap] ' + a.join(' ') + '\n');
const out  = (k, v) => process.stdout.write(`${k}=${v}\n`);

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
function ensureServiceAccount() {
	const pw = hashPasswordSSHA512(SVC_PASS);
	if (entryExists(SVC_DN)) {
		log(`Service account ${SVC_DN} exists — resetting password to ./config`);
		const r = ldapModify([
			`dn: ${SVC_DN}`,
			'changetype: modify',
			'replace: userPassword',
			`userPassword: ${pw}`,
			'',
		].join('\n'));
		if (r.code !== 0) log('  password reset warning:', r.stderr.trim());
		return;
	}
	log(`Creating service account ${SVC_DN}`);
	const r = ldapAdd([
		`dn: ${SVC_DN}`,
		'objectClass: organizationalRole',
		'objectClass: simpleSecurityObject',
		'objectClass: top',
		'cn: ldapclient',
		`userPassword: ${pw}`,
		'',
	].join('\n'));
	if (r.code !== 0) throw new Error(`ldapadd service account failed: ${r.stderr.trim()}`);
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

async function createClient(token) {
	const res = await fetch(`${SSO_INTERNAL}/api/oauth/client`, {
		method: 'POST',
		headers: { 'auth-token': token, 'Content-Type': 'application/json' },
		body: JSON.stringify({
			name: CLIENT_NAME,
			description: 'theta-env proxy (auto-registered)',
			redirect_uris: [REDIRECT_URI],
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
	log(`Created OAuth client ${CLIENT_NAME} (${id})`);
	return { id, secret };
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

async function seedDirectory(token, clientId) {
	let resources = ((await dirGet(token, 'resources')).results) || [];

	// Create a resource unless its slug already exists (operator-owned then).
	async function ensure(kind, name, slug, parentId, metadata) {
		const found = resources.find((r) => r.slug === slug);
		if (found) {
			log(`  directory: ${kind} '${slug}' exists — keeping`);
			return found;
		}
		const body = { kind, name, slug, metadata: metadata || {} };
		if (parentId) body.hostId = parentId; // POST creates the parent edge
		const created = (await dirPost(token, 'resources', body)).results;
		resources.push(created);
		log(`  directory: created ${kind} '${slug}'`);
		return created;
	}

	const site  = await ensure('site', ORG, slugify(DOMAIN || ORG), null, {});
	const host  = await ensure('host', 'Stack host', 'stack-host', site.id, {});
	await ensure('service', 'SSO Manager', 'sso-manager', host.id, { address: `https://${SSO_HOST}` });
	// Proxy = the node management UI; OpenResty = the data plane every hostname
	// in the stack actually flows through (80/443). Two faces, two entries.
	const psvc = await ensure('service', 'Proxy', 'proxy', host.id, { address: `https://${PROXY_HOST}` });
	// OpenLDAP is independently consumed — Linux hosts authenticate against it
	// (PAM/SSSD, sudoRole, sshPublicKey) and LDAP-native apps bind directly
	// (see the SSO's /integrations page) — so it gets its own entry. Advertise
	// the operator-configured LDAPS hostname when set, else the SSO host.
	const LDAPS_HOST = (sso.ldap && sso.ldap.ldapsHost) || SSO_HOST;
	await ensure('service', 'OpenLDAP Directory', 'openldap', host.id, {
		address: `ldaps://${LDAPS_HOST}:636`,
		subType: 'openldap',
	});
	// Wildcard address: OpenResty fronts every host under the domain (same
	// */** wildcard convention the proxy's Host records use).
	await ensure('service', 'OpenResty Edge', 'openresty', host.id, {
		address: DOMAIN ? `https://*.${DOMAIN}` : `https://${PROXY_HOST}`,
		subType: 'openresty',
	});

	// Link the proxy's OAuth client (Resource-backed since sso-manager 1.3.0)
	// under its service, if it appears in the directory and isn't linked yet.
	if (clientId) {
		const oauthRes = resources.find((r) => r.id === clientId);
		if (oauthRes) {
			const edges = ((await dirGet(token, 'edges')).results) || [];
			const linked = edges.some((e) => e.childId === clientId);
			if (!linked) {
				await dirPost(token, 'edges', { parentId: psvc.id, childId: clientId, relation: 'oauth' });
				log(`  directory: linked OAuth client under 'proxy'`);
			}
		}
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

		// Seed the directory (site/host/services + OAuth client link). Never
		// fails the bootstrap — warn and continue.
		try {
			log('Seeding directory resources...');
			await seedDirectory(token, resolvedClientId);
		} catch (e) {
			log(`WARNING: directory seed failed (${e.message || e}) — continuing`);
		}

		log('Done.');
		process.exit(0);
	} catch (e) {
		process.stderr.write(`[bootstrap] ERROR: ${e.message || e}\n`);
		process.exit(1);
	}
})();