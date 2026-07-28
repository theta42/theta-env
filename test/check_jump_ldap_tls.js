#!/usr/bin/env node
'use strict';

// Regression guard for bootstrap.js's generated jump-secrets.js template:
// its ldap block must use ldaps:// (implicit TLS, :636), never ldap:// (:389),
// as long as tlsOptions is set alongside it.
//
// ldapts treats a non-empty tlsOptions as "use implicit TLS" regardless of URL
// scheme, and jump-host's LDAP client always sets tlsOptions -- so ldap://
// + tlsOptions opens a raw TLS handshake against a port serving plaintext
// LDAP. The server silently drops the connection before any LDAP message
// parses, and every operation (getUser, checkPassword, ...) then fails
// identically -- indistinguishable from a wrong password. This shipped once
// (every SSH login to jump-host failed, for any account, any password) before
// being root-caused against a real deployment. Static, not a require()+exec
// of bootstrap.js, because bootstrap.js is a self-running provisioning script
// with real side effects (LDAP writes, API calls), not a library.

const fs = require('fs');
const path = require('path');

const BOOTSTRAP_PATH = path.join(__dirname, '..', 'bootstrap', 'bootstrap.js');
const src = fs.readFileSync(BOOTSTRAP_PATH, 'utf8');

// Isolate the generated jump-secrets.js template (the backtick string
// assigned to `body` inside writeJumpSecrets) rather than scanning the whole
// file, so this only ever looks at what's actually written to the deployed
// config -- not, say, a comment or an unrelated ldap:// URL elsewhere.
// bootstrap.js's own source has literal backslash-t escape sequences inside
// the backtick string (they only become real tabs when the template
// literal is actually evaluated) -- so these patterns match `\t` as two
// literal characters, not a real tab byte.
const bodyMatch = /const body = `([\s\S]*?)`;\n\tfs\.writeFileSync\(JUMP_SECRETS/.exec(src);
if (!bodyMatch) {
	console.error('check_jump_ldap_tls: could not locate the jump-secrets.js template in bootstrap.js — did writeJumpSecrets change shape?');
	process.exit(1);
}
const template = bodyMatch[1];

// Bounded by the next top-level key (sso:) rather than the ldap block's own
// closing brace, which is more robust to exactly how it's indented/escaped.
const ldapBlockMatch = /ldap:\s*\{([\s\S]*?)\\tsso:\s*\{/.exec(template);
if (!ldapBlockMatch) {
	console.error('check_jump_ldap_tls: could not find the ldap: {...} block in the jump-secrets.js template.');
	process.exit(1);
}
const ldapBlock = ldapBlockMatch[1];

const hasTlsOptions = /tlsOptions\s*:/.test(ldapBlock);
const urlMatch = /url:\s*'([^']+)'/.exec(ldapBlock);
const url = urlMatch ? urlMatch[1] : null;

if (!url) {
	console.error('check_jump_ldap_tls: no url found in the ldap block.');
	process.exit(1);
}

if (hasTlsOptions && !url.startsWith('ldaps://')) {
	console.error(
		`check_jump_ldap_tls: jump-secrets.js template sets tlsOptions but url is "${url}" (not ldaps://). ` +
		'This is the exact bug that broke every SSH login to jump-host -- see the comment above this check.'
	);
	process.exit(1);
}

console.log(`check_jump_ldap_tls: OK (url=${url}, tlsOptions=${hasTlsOptions})`);
