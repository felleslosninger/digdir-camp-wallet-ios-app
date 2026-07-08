import { Router } from 'express';
import crypto from 'node:crypto';
import { db } from '../db/index.js';
import { hmac, encrypt, randomToken } from '../crypto/index.js';
import { buildSignedRequestObject, VERIFIER_CLIENT_ID } from '../crypto/requestObject.js';
import { jwkThumbprint, jwkToPublicKey, jwkToRawPoint } from '../crypto/jwk.js';

export const router = Router();

function base64url(input) {
  return Buffer.from(input, 'base64url');
}

function parseJwt(jwt) {
  const [headerB64, payloadB64, sigB64] = jwt.split('.');
  if (!headerB64 || !payloadB64 || !sigB64) throw new Error('malformed JWT');
  return {
    header: JSON.parse(base64url(headerB64).toString('utf8')),
    payload: JSON.parse(base64url(payloadB64).toString('utf8')),
    signingInput: `${headerB64}.${payloadB64}`,
    signature: base64url(sigB64),
  };
}

function verifyEs256(publicKey, signingInput, signature) {
  return crypto.verify('sha256', Buffer.from(signingInput), { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature);
}

// Verifies a Holder Binding proof: a JWT self-signed by the wallet's Secure
// Enclave signing key (see HolderBindingKey.swift). Used TWICE in this flow
// — once at presentation time (proves "I hold the key behind this nonce's
// committed thumbprint"), and again at registration time (proves "I still
// hold it" over a fresh, single-use session_token). Same verification
// logic both times; only what's being signed over differs.
function verifySelfSignedJwt(jwt) {
  const { header, payload, signingInput, signature } = parseJwt(jwt);
  if (header.alg !== 'ES256') throw new Error('unexpected alg');
  const publicKey = jwkToPublicKey(header.jwk);
  if (!verifyEs256(publicKey, signingInput, signature)) throw new Error('signature verification failed');
  return payload;
}

const SESSION_TTL_MS = 10 * 60 * 1000;
const REGISTRATION_TTL_MS = 5 * 60 * 1000;

// The Universal Link domain the app is registered to intercept (would need
// a real apple-app-site-association file hosted there in production). We
// use it only to shape the URL — actual local testing uses the
// `eudiwallet-inbox://` custom scheme as a stand-in (see server/README.md).
const UNIVERSAL_LINK_BASE = process.env.UNIVERSAL_LINK_BASE || 'https://inbox-backend.example';

// Step 1: app computes an RFC 7638 thumbprint of its ECDH messaging public
// key and commits to it BEFORE any presentation happens, by baking it into
// the OpenID4VP request's nonce as "<uuid>.<thumbprint>". This means the
// server already knows exactly which key it expects long before it sees
// any credential disclosure — a swapped-in different key at a later step
// can be caught by simple string comparison, not just trust in a
// self-asserted claim inside the presentation itself.
router.post('/keybinding/start', (req, res) => {
  const { key_thumbprint, fcm_token, device_id } = req.body || {};
  if (!key_thumbprint || !fcm_token || !device_id) {
    return res.status(400).json({ error: 'key_thumbprint, fcm_token and device_id are required' });
  }

  const state = randomToken(16);
  const nonce = `${randomToken(12)}.${key_thumbprint}`;
  const now = Date.now();

  db.prepare(`
    INSERT INTO activation_session (state, nonce, key_thumbprint, fcm_token, device_id, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(
    state, nonce, key_thumbprint, fcm_token, device_id,
    new Date(now).toISOString(), new Date(now + SESSION_TTL_MS).toISOString()
  );

  res.json({
    requestUri: `${UNIVERSAL_LINK_BASE}/keybinding/request-object/${state}`,
    state,
  });
});

// Request by Reference target — unchanged from before.
router.get('/keybinding/request-object/:state', (req, res) => {
  const session = db.prepare('SELECT * FROM activation_session WHERE state = ?').get(req.params.state);
  if (!session) return res.status(404).json({ error: 'Unknown or expired keybinding session' });

  const jwt = buildSignedRequestObject({
    nonce: session.nonce,
    state: session.state,
    responseUri: `${UNIVERSAL_LINK_BASE}/keybinding/callback`,
    presentationDefinition: {
      id: 'pid-key-binding',
      input_descriptors: [{ id: 'pid', format: { 'vc+sd-jwt': {} } }],
    },
  });

  res.type('application/oauth-authz-req+jwt').send(jwt);
});

// Step 2: wallet posts its OpenID4VP response here after PID presentation.
// Verifying the FULL vp_token (a real PID issuer's signature chain) is
// still MOCKED (`mock_pid`) — no real PID issuer integration here. The Key
// Binding JWT signature IS really verified: it must be signed over THIS
// request's exact nonce (which already contains our committed thumbprint),
// so a captured/replayed KB-JWT from a different session is rejected
// immediately by nonce mismatch — no key comparison needed at this step.
//
// On success this does NOT register anything yet. It only proves "the PID
// presentation succeeded, and was bound to the committed thumbprint" and
// hands back a single-use session_token — actual registration happens in
// step 3, requiring a FRESH proof of key possession.
router.post('/keybinding/callback', (req, res) => {
  const { state, mock_pid, key_binding_jwt } = req.body || {};
  const session = db.prepare('SELECT * FROM activation_session WHERE state = ?').get(state);
  if (!session) return res.status(400).json({ error: 'Unknown or expired keybinding session' });
  if (new Date(session.expires_at).getTime() < Date.now()) {
    db.prepare('DELETE FROM activation_session WHERE state = ?').run(state);
    return res.status(400).json({ error: 'Session expired — start again' });
  }

  let kbPayload;
  try {
    kbPayload = verifySelfSignedJwt(key_binding_jwt);
    if (kbPayload.nonce !== session.nonce) throw new Error('nonce mismatch — possible replay');
    if (kbPayload.aud !== VERIFIER_CLIENT_ID) throw new Error('audience mismatch');
  } catch (err) {
    return res.status(400).json({ error: `Key Binding JWT verification failed: ${err.message}` });
  }

  // --- MOCK: real code additionally verifies the vp_token's PID issuer
  // signature chain here (out of scope — no real PID issuer integration). --
  const pid = mock_pid || '01020312345';
  // ---------------------------------------------------------------------

  const sessionToken = randomToken(24);
  const now = Date.now();
  db.prepare(`
    INSERT INTO pending_registration
      (session_token, pid_hash, committed_thumbprint, fcm_token, device_id, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(
    sessionToken, hmac(pid), session.key_thumbprint, session.fcm_token, session.device_id,
    new Date(now).toISOString(), new Date(now + REGISTRATION_TTL_MS).toISOString()
  );

  db.prepare('DELETE FROM activation_session WHERE state = ?').run(state);
  res.json({ sessionToken });
});

// Step 3: registration proper. The app now presents its ACTUAL public key
// (as a JWK) plus a fresh signature (pop_jwt) over `session_token`,
// completely decoupled from the OpenID4VP presentation itself. Two
// independent checks must both pass:
//   1. thumbprint(public_key_jwk) === the thumbprint committed at step 1 —
//      catches any attempt to swap in a different key after the fact.
//   2. pop_jwt is validly signed, over exactly THIS session_token — proves
//      whoever is registering right now still holds the private key, not
//      just that they once captured a valid session_token off the wire.
router.post('/keybinding/register', (req, res) => {
  const { session_token, fcm_token, public_key_jwk, pop_jwt } = req.body || {};
  if (!session_token || !fcm_token || !public_key_jwk || !pop_jwt) {
    return res.status(400).json({ error: 'session_token, fcm_token, public_key_jwk and pop_jwt are required' });
  }

  const pending = db.prepare('SELECT * FROM pending_registration WHERE session_token = ?').get(session_token);
  // Single-use: consume immediately regardless of outcome, so a
  // captured/retried session_token cannot be used twice.
  if (pending) db.prepare('DELETE FROM pending_registration WHERE session_token = ?').run(session_token);

  if (!pending) return res.status(400).json({ error: 'Unknown, expired, or already-used session_token' });
  if (new Date(pending.expires_at).getTime() < Date.now()) {
    return res.status(400).json({ error: 'Registration session expired — start again' });
  }

  const actualThumbprint = jwkThumbprint(public_key_jwk);
  if (actualThumbprint !== pending.committed_thumbprint) {
    return res.status(400).json({ error: 'public_key_jwk does not match the key committed at presentation time' });
  }

  // Pinning moment: this is the ONE time we accept the holder-binding
  // public key on a self-asserted, trust-on-first-use basis. From here on,
  // every fetch-challenge signature is checked against THIS specific
  // pinned key (see messages.js) — not a fresh self-asserted one each time.
  let holderBindingPublicKey;
  try {
    const popPayload = verifySelfSignedJwt(pop_jwt);
    if (popPayload.sub !== session_token) throw new Error('pop_jwt is not bound to this session_token');
    holderBindingPublicKey = jwkToRawPoint(parseJwt(pop_jwt).header.jwk);
  } catch (err) {
    return res.status(400).json({ error: `Proof of possession failed: ${err.message}` });
  }

  const devicePublicKey = jwkToRawPoint(public_key_jwk);
  const { ciphertext, iv } = encrypt(fcm_token);
  const fcmTokenHash = hmac(fcm_token);
  const now = new Date().toISOString();

  const existing = db.prepare('SELECT id FROM inbox_registration WHERE pid_hash = ?').get(pending.pid_hash);
  const id = existing?.id || crypto.randomUUID();

  db.prepare(`
    INSERT INTO inbox_registration
      (id, pid_hash, device_public_key, holder_binding_public_key, fcm_token_encrypted, fcm_token_iv, fcm_token_hash,
       device_id, created_at, updated_at, last_verified_at, revoked_at)
    VALUES (@id, @pid_hash, @device_public_key, @holder_binding_public_key, @fcm_token_encrypted, @fcm_token_iv, @fcm_token_hash,
            @device_id, @created_at, @updated_at, @last_verified_at, NULL)
    ON CONFLICT(pid_hash) DO UPDATE SET
      device_public_key = excluded.device_public_key,
      holder_binding_public_key = excluded.holder_binding_public_key,
      fcm_token_encrypted = excluded.fcm_token_encrypted,
      fcm_token_iv = excluded.fcm_token_iv,
      fcm_token_hash = excluded.fcm_token_hash,
      device_id = excluded.device_id,
      updated_at = excluded.updated_at,
      last_verified_at = excluded.last_verified_at,
      revoked_at = NULL
  `).run({
    id,
    pid_hash: pending.pid_hash,
    device_public_key: devicePublicKey,
    holder_binding_public_key: holderBindingPublicKey,
    fcm_token_encrypted: ciphertext,
    fcm_token_iv: iv,
    fcm_token_hash: fcmTokenHash,
    device_id: pending.device_id,
    created_at: now,
    updated_at: now,
    last_verified_at: now,
  });

  res.json({ status: 'bound', registrationId: id });
});
