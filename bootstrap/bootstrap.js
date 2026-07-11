#!/usr/bin/env node
/*
 * theta-env bootstrap — runs inside the sso-manager container to wire the
 * proxy into a fresh SSO Manager. Invoked by setup.sh:
 *
 *   docker compose exec sso-manager node /bootstrap/bootstrap.js
 *
 * It is intentionally self-contained: only Node built-ins (child_process,
 * crypto) + global fetch. No requiring of the SSO's internal models (which
 * would read the wrong conf.ldap in a docker-exec process and risk model
 * side effects). LDAP ops use the openldap-clients binaries (ldapadd /
 * ldapsearch / ldapmodify) with explicit admin creds from the environment;
 * the OAuth client is created via the SSO's own HTTP API (logging in as the
 * bootstrapped admin, which also validates the admin password end-to-end).
 *
 * Idempotent: re-running converges to the .env values. The LDAP service
 * account + admin passwords are reset to .env on each run; the OAuth client
 * is created if missing, or rotated only if proxy.env is absent (a lost
 * proxy.env needs a fresh secret the proxy can actually read).
 *
 * Inputs (env, set by setup.sh from .env):
 *   LDAP_BASE_DN, LDAP_ADMIN_PASS                 — directory root creds
 *   BOOTSTRAP_ADMIN_UID/PASS/EMAIL                — first admin to create
 *   LDAP_SERVICE_PASS                             — proxy bind account password
 *   SSO_HOST, PROXY_HOST                          — public hostnames
 *   PROXY_ENV_EXISTS (1|0)                        — set by setup.sh
 *
 * Output (stdout, KEY=VALUE for setup.sh to parse): CLIENT_ID, CLIENT_SECRET,
 * and ALREADY_CONFIGURED. Progress logs go to stderr.
 */
'use strict';

const { execFileSync } = require('child_process');
const crypto = require('crypto');

const BASE_DN    = process.env.LDAP_BASE_DN || 'dc=example,dc=com';
const ADMIN_PASS = process.env.LDAP_ADMIN_PASS || 'admin';
const BIND_DN    = `cn=admin,${BASE_DN}`;
const LDAP_URL   = 'ldap://localhost:389';

const ADMIN_UID   = process.env.BOOTSTRAP_ADMIN_UID   || 'admin';
const ADMIN_PASS  = process.env.BOOTSTRAP_ADMIN_PASS  || 'admin';
const ADMIN_EMAIL = process.env.BOOTSTRAP_ADMIN_EMAIL || '';
const SVC_PASS    = process.env.LDAP_SERVICE_PASS || 'service';

const SSO_HOST   = process.env.SSO_HOST   || 'sso.example.com';
const PROXY_HOST = process.env.PROXY_HOST || 'proxy.example.com';
const PROXY_ENV_EXISTS = process.env.PROXY_ENV_EXISTS === '1';

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
		log(`Service account ${SVC_DN} exists — resetting password to .env`);
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
		'objectClass: top',
		'cn: ldapclient',
		`userPassword: ${pw}`,
		'',
	].join('\n'));
	if (r.code !== 0) throw new Error(`ldapadd service account failed: ${r.stderr.trim()}`);
}

// ── 2. First admin user ─────────────────────────────────────────────────────
function ensureAdmin() {
	const pw = hashPasswordSSHA512(ADMIN_PASS);
	if (entryExists(ADMIN_DN)) {
		log(`Admin ${ADMIN_DN} exists — resetting password to .env and ensuring groups`);
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
		body: JSON.stringify({ uid: ADMIN_UID, password: ADMIN_PASS }),
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
async function findClient(token) {
	const res = await fetch(`${SSO_INTERNAL}/api/oauth/client`, {
		headers: { 'auth-token': token },
	});
	if (!res.ok) throw new Error(`list OAuth clients failed (${res.status})`);
	const data = await res.json();
	const list = (data && data.results) || [];
	return list.find((c) => c.name === CLIENT_NAME) || null;
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

(async function main() {
	try {
		log(`Base DN: ${BASE_DN}`);
		ensureServiceAccount();
		ensureAdmin();
		const token = await login();

		const existing = await findClient(token);
		if (!existing) {
			const { id, secret } = await createClient(token);
			out('CLIENT_ID', id);
			out('CLIENT_SECRET', secret);
			out('ALREADY_CONFIGURED', '0');
		} else if (PROXY_ENV_EXISTS) {
			log(`OAuth client ${CLIENT_NAME} exists and proxy.env present — nothing to do`);
			out('CLIENT_ID', existing.client_id);
			out('CLIENT_SECRET', '__UNCHANGED__');
			out('ALREADY_CONFIGURED', '1');
		} else {
			log(`OAuth client ${CLIENT_NAME} exists but proxy.env is missing — rotating secret`);
			const { id, secret } = await rotateClient(token, existing.client_id);
			out('CLIENT_ID', id);
			out('CLIENT_SECRET', secret);
			out('ALREADY_CONFIGURED', '0');
		}
		log('Done.');
		process.exit(0);
	} catch (e) {
		process.stderr.write(`[bootstrap] ERROR: ${e.message || e}\n`);
		process.exit(1);
	}
})();