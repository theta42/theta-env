const test = require('node:test');
const assert = require('node:assert');

test('Integration Test Suite', async (t) => {
  
  await t.test('SSO Manager should be running and healthy', async () => {
    const res = await fetch('http://localhost:3001/health');
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.strictEqual(body.status, 'ok');
  });

  await t.test('Proxy should be running and route to SSO Manager', async () => {
    // Testing the proxy routes traffic to SSO manager
    const res = await fetch('http://sso.localtest.me/.well-known/openid-configuration');
    assert.ok(res.status === 200 || res.status === 301);
    const body = await res.json();
    assert.ok(body.issuer);
  });

  await t.test('Proxy Management API should be running', async () => {
    const res = await fetch('http://localhost:3000/health');
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.strictEqual(body.status, 'ok');
  });

  await t.test('OpenBao should be running and healthy', async () => {
    // Port 8080 is mapped to OpenBao's 8200 in docker-compose.yml
    const res = await fetch('http://localhost:8080/v1/sys/health');
    assert.ok(res.status === 200 || res.status === 501); // 501 means not initialized/sealed, but responsive
  });

  await t.test('SSO Manager should proxy to OpenBao (integration test)', async () => {
    // Test if SSO Manager proxies to OpenBao
    // Without authentication, this should return 401 Unauthorized from SSO Manager's middleware
    const res = await fetch('http://localhost:3001/api/vault/sys/health');
    assert.strictEqual(res.status, 401);
  });
});
