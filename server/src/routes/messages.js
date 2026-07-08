import { Router } from 'express';
import crypto from 'node:crypto';
import rateLimit from 'express-rate-limit';
import { db } from '../db/index.js';
import { hmac, randomToken, decrypt } from '../crypto/index.js';
import { encryptForRecipient } from '../crypto/ecies.js';
import { rawPointToPublicKey } from '../crypto/jwk.js';
import { sendSilentWakeUpPush } from '../push/apns.js';
import { authenticateSender } from '../middleware/senderAuth.js';

export const router = Router();

const CHALLENGE_TTL_MS = 2 * 60 * 1000;

// One compromised or misbehaving sender key shouldn't be able to flood
// every recipient. Keyed per API key (not per IP) so one agency's traffic
// never throttles another's, and a leaked key is capped in blast radius.
const sendRateLimit = rateLimit({
  windowMs: 60 * 1000,
  limit: 60,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.sender.id,
});

// Sender-side (e.g. NAV's backend calls this — never the app). The sender
// must already know the recipient's device_public_key: our /messages/key
// lookup below hands that out by pid_hash, since it's not secret. Encryption
// happens HERE, in the sender's trust boundary — by the time this request
// body is built, the plaintext is already gone. Our own server only ever
// receives ciphertext.
//
// `sender_id` is no longer taken from the request body — it comes from
// whichever API key authenticated the call, so a caller can never claim to
// be an agency it isn't. See middleware/senderAuth.js and
// scripts/create-sender.js.
router.post('/messages/send', authenticateSender, sendRateLimit, async (req, res) => {
  const { pid, plaintext } = req.body || {};
  if (!pid || !plaintext) {
    return res.status(400).json({ error: 'pid and plaintext are required' });
  }
  const senderId = req.sender.name;

  const registration = db.prepare(
    'SELECT id, device_public_key, fcm_token_encrypted, fcm_token_iv FROM inbox_registration WHERE pid_hash = ? AND revoked_at IS NULL'
  ).get(hmac(pid));
  if (!registration) return res.status(404).json({ error: 'No active inbox registration for this PID' });

  const encrypted = encryptForRecipient(plaintext, registration.device_public_key);
  // Proof-of-content: a hash of the ORIGINAL plaintext, computed here (the
  // only place plaintext ever exists in this whole flow) before it's
  // discarded. Lets a later dispute be resolved by reproducing the
  // plaintext and checking it hashes to this value — without us ever
  // having stored it. See schema.sql for the eIDAS-shaped reasoning.
  const contentHash = crypto.createHash('sha256').update(plaintext, 'utf8').digest();

  const id = crypto.randomUUID();
  db.prepare(`
    INSERT INTO message
      (id, recipient_registration_id, sender_id, ciphertext, iv, sender_ephemeral_public_key, hkdf_salt, content_hash, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    id, registration.id, senderId, encrypted.ciphertext, encrypted.iv,
    encrypted.ephemeralPublicKey, encrypted.salt, contentHash, new Date().toISOString()
  );

  // Content-free silent push — decrypted here ONLY to get the routing
  // address (the device's APNs token), never to touch message content.
  // The push payload itself carries nothing but "you have mail"; the app
  // fetches and decrypts the real content itself via /messages/fetch.
  try {
    const deviceToken = decrypt(registration.fcm_token_encrypted, registration.fcm_token_iv);
    await sendSilentWakeUpPush(deviceToken);
  } catch (err) {
    // Message is already stored — only push delivery failed (e.g. APNs
    // key not configured yet in this environment). Don't lose the message.
    console.error('[APNs] wake-up push failed', err);
    return res.json({ status: 'queued', messageId: id, pushDelivery: 'failed' });
  }

  res.json({ status: 'queued', messageId: id });
});

// Step 1 of fetch authentication: the device asks for a fresh, single-use
// nonce before it can retrieve anything. This is the piece that was
// missing before — confidentiality (ECIES above) says nobody CAN read a
// message without the right key; this says nobody may even ASK for the
// ciphertext list without proving they're the right device first.
router.get('/messages/challenge/:registrationId', (req, res) => {
  const registration = db.prepare(
    'SELECT id FROM inbox_registration WHERE id = ? AND revoked_at IS NULL'
  ).get(req.params.registrationId);
  if (!registration) return res.status(404).json({ error: 'Unknown or revoked registration' });

  const nonce = randomToken(16);
  const now = Date.now();
  db.prepare(`
    INSERT INTO fetch_challenge (nonce, registration_id, created_at, expires_at)
    VALUES (?, ?, ?, ?)
  `).run(nonce, registration.id, new Date(now).toISOString(), new Date(now + CHALLENGE_TTL_MS).toISOString());

  res.json({ nonce });
});

// Step 2: the device signs the nonce with its holder-binding private key
// (the SAME key pinned during `/keybinding/register` — see keyBinding.js)
// and submits the raw signature. Only after that verifies do we hand back
// ciphertext. `signature` is the raw r||s (64-byte) ECDSA format, matching
// everywhere else in this codebase (JWS ES256 style) — no DER conversion.
router.post('/messages/fetch', (req, res) => {
  const { registration_id, nonce, signature } = req.body || {};
  if (!registration_id || !nonce || !signature) {
    return res.status(400).json({ error: 'registration_id, nonce and signature are required' });
  }

  const challenge = db.prepare(
    'SELECT * FROM fetch_challenge WHERE nonce = ? AND registration_id = ?'
  ).get(nonce, registration_id);
  // Single-use regardless of outcome.
  if (challenge) db.prepare('DELETE FROM fetch_challenge WHERE nonce = ?').run(nonce);

  if (!challenge) return res.status(400).json({ error: 'Unknown, expired, or already-used challenge' });
  if (new Date(challenge.expires_at).getTime() < Date.now()) {
    return res.status(400).json({ error: 'Challenge expired — request a new one' });
  }

  const registration = db.prepare(
    'SELECT id, holder_binding_public_key FROM inbox_registration WHERE id = ? AND revoked_at IS NULL'
  ).get(registration_id);
  if (!registration) return res.status(404).json({ error: 'Unknown or revoked registration' });

  const publicKey = rawPointToPublicKey(registration.holder_binding_public_key);
  const valid = crypto.verify(
    'sha256',
    Buffer.from(nonce),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    Buffer.from(signature, 'base64url')
  );
  if (!valid) return res.status(401).json({ error: 'Signature verification failed — wrong device key' });

  const rows = db.prepare(`
    SELECT id, sender_id, ciphertext, iv, sender_ephemeral_public_key, hkdf_salt, content_hash, created_at
    FROM message WHERE recipient_registration_id = ? ORDER BY created_at DESC
  `).all(registration.id);

  res.json(rows.map((r) => ({
    id: r.id,
    senderId: r.sender_id,
    ciphertext: r.ciphertext.toString('base64url'),
    iv: r.iv.toString('base64url'),
    senderEphemeralPublicKey: r.sender_ephemeral_public_key.toString('base64url'),
    hkdfSalt: r.hkdf_salt.toString('base64url'),
    contentHash: r.content_hash.toString('base64url'),
    createdAt: r.created_at,
  })));
});
