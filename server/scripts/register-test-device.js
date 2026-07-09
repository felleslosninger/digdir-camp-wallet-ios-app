#!/usr/bin/env node
// Runs the FULL three-step key-binding flow (start -> callback -> register)
// against a running local server, so you don't have to hand-craft curl
// commands and JWTs yourself just to get a test registration in place
// before testing /messages/send or /messages/fetch.
//
// Usage:
//   node scripts/register-test-device.js <pid> [fcm_token] [base_url]
//
// Example:
//   node scripts/register-test-device.js 99887766554 6c9a3edb...real-apns-token http://localhost:3001
//
// If fcm_token is omitted, a fake placeholder is used (fine for testing
// /messages/send's storage/auth logic, but no real push will be delivered).
import crypto from 'node:crypto';

const pid = process.argv[2];
const fcmToken = process.argv[3] || 'test-fcm-token-' + crypto.randomBytes(4).toString('hex');
const baseUrl = process.argv[4] || 'http://localhost:3001';

if (!pid) {
  console.error('Usage: node scripts/register-test-device.js <pid> [fcm_token] [base_url]');
  process.exit(1);
}

function b64url(buf) {
  return buf.toString('base64url');
}

function generateEcKeyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-65);
  return {
    privateKey,
    jwk: { crv: 'P-256', kty: 'EC', x: b64url(raw.subarray(1, 33)), y: b64url(raw.subarray(33, 65)) },
  };
}

function signJwt(privateKey, jwk, payload) {
  const header = { typ: 'kb+jwt', alg: 'ES256', jwk };
  const encode = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const signingInput = `${encode(header)}.${encode(payload)}`;
  const sig = crypto.sign('sha256', Buffer.from(signingInput), { key: privateKey, dsaEncoding: 'ieee-p1363' });
  return `${signingInput}.${sig.toString('base64url')}`;
}

async function main() {
  const messagingKey = generateEcKeyPair();
  const holderKey = generateEcKeyPair();
  const thumbprint = crypto.createHash('sha256').update(JSON.stringify(messagingKey.jwk)).digest('base64url');

  console.log(`Registering test device for PID "${pid}" against ${baseUrl} ...`);

  // Step 1: commit
  const startRes = await fetch(`${baseUrl}/keybinding/start`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key_thumbprint: thumbprint, fcm_token: fcmToken, device_id: 'test-device' }),
  }).then((r) => r.json());
  if (!startRes.state) throw new Error(`/keybinding/start failed: ${JSON.stringify(startRes)}`);

  // Fetch the signed Request Object to read its nonce
  const requestObjectUrl = new URL(startRes.requestUri);
  const localRequestObjectUrl = `${baseUrl}${requestObjectUrl.pathname}`;
  const jwt = await fetch(localRequestObjectUrl).then((r) => r.text());
  const nonce = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString()).nonce;

  // Step 2: present (mocked PID presentation)
  const keyBindingJwt = signJwt(holderKey.privateKey, holderKey.jwk, {
    aud: 'inbox-backend.example',
    nonce,
    sd_hash: 'mock-sd-hash',
  });
  const callbackRes = await fetch(`${baseUrl}/keybinding/callback`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ state: startRes.state, mock_pid: pid, key_binding_jwt: keyBindingJwt }),
  }).then((r) => r.json());
  if (!callbackRes.sessionToken) throw new Error(`/keybinding/callback failed: ${JSON.stringify(callbackRes)}`);

  // Step 3: register (fresh proof of possession)
  const popJwt = signJwt(holderKey.privateKey, holderKey.jwk, {
    sub: callbackRes.sessionToken,
    jti: crypto.randomUUID(),
  });
  const registerRes = await fetch(`${baseUrl}/keybinding/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      session_token: callbackRes.sessionToken,
      fcm_token: fcmToken,
      public_key_jwk: messagingKey.jwk,
      pop_jwt: popJwt,
    }),
  }).then((r) => r.json());
  if (!registerRes.registrationId) throw new Error(`/keybinding/register failed: ${JSON.stringify(registerRes)}`);

  console.log();
  console.log('Registered successfully.');
  console.log(`  registrationId: ${registerRes.registrationId}`);
  console.log(`  pid used:       ${pid}`);
  console.log();
  console.log('You can now send a message with:');
  console.log(`  node scripts/create-sender.js <name>   # if you don't have an API key yet`);
  console.log(`  curl -X POST ${baseUrl}/messages/send -H "Authorization: Bearer <api_key>" \\`);
  console.log(`    -H "Content-Type: application/json" -d '{"pid":"${pid}","plaintext":"hei!"}'`);
}

main().catch((err) => {
  console.error('Failed:', err.message);
  process.exit(1);
});
