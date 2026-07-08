import crypto from 'node:crypto';

// ECIES (Elliptic Curve Integrated Encryption Scheme) using P-256 + HKDF +
// AES-256-GCM. This is what lets a sender (e.g. NAV) encrypt a message for a
// specific device WITHOUT any prior interactive handshake — only the
// recipient's long-lived public key is needed. The server relays the
// output; it never sees the shared secret or the plaintext.
//
// Per-message flow (sender side, `encryptForRecipient`):
//   1. Generate a fresh ephemeral P-256 keypair (used ONCE, then discarded).
//   2. ECDH(ephemeral_private, recipient_public) -> shared secret.
//   3. HKDF-SHA256(shared secret, random salt) -> 256-bit AES key.
//   4. AES-256-GCM encrypt the message with that key.
//   5. Send { ciphertext, iv, ephemeral_public_key, salt } — NOT the shared
//      secret or the AES key, which are derived and discarded immediately.
//
// Device side mirrors this: ECDH(device_private [Secure Enclave],
// ephemeral_public) yields the SAME shared secret (that's the ECDH
// property), so the same HKDF + AES key can be re-derived locally.

const CURVE = 'prime256v1'; // P-256 / secp256r1 — the curve Secure Enclave supports

export function generateEphemeralKeyPair() {
  return crypto.generateKeyPairSync('ec', { namedCurve: CURVE });
}

function deriveAesKey(sharedSecret, salt) {
  // HKDF-Extract-and-Expand (RFC 5869). The salt need not be secret — it
  // just ensures two messages never derive the same key even by accident.
  return crypto.hkdfSync('sha256', sharedSecret, salt, Buffer.from('inbox-e2ee-v1'), 32);
}

// recipientPublicKeyPoint: Buffer, X9.63 uncompressed EC point (0x04 || X || Y)
export function encryptForRecipient(plaintext, recipientPublicKeyPoint) {
  const ephemeral = generateEphemeralKeyPair();
  const recipientKey = crypto.createPublicKey({
    key: ecPointToDer(recipientPublicKeyPoint),
    format: 'der',
    type: 'spki',
  });

  const sharedSecret = crypto.diffieHellman({
    privateKey: ephemeral.privateKey,
    publicKey: recipientKey,
  });

  const salt = crypto.randomBytes(16);
  const aesKey = Buffer.from(deriveAesKey(sharedSecret, salt));

  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', aesKey, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final(), cipher.getAuthTag()]);

  return {
    ciphertext,
    iv,
    salt,
    ephemeralPublicKey: exportRawPoint(ephemeral.publicKey),
  };
}

// Only ever called in a test/simulation context on the server, to prove the
// scheme round-trips. In production this logic lives ONLY on the device.
export function decryptWithPrivateKey(encrypted, recipientPrivateKey) {
  const ephemeralKey = crypto.createPublicKey({
    key: ecPointToDer(encrypted.ephemeralPublicKey),
    format: 'der',
    type: 'spki',
  });

  const sharedSecret = crypto.diffieHellman({
    privateKey: recipientPrivateKey,
    publicKey: ephemeralKey,
  });

  const aesKey = Buffer.from(deriveAesKey(sharedSecret, encrypted.salt));
  const authTag = encrypted.ciphertext.subarray(encrypted.ciphertext.length - 16);
  const ciphertext = encrypted.ciphertext.subarray(0, encrypted.ciphertext.length - 16);

  const decipher = crypto.createDecipheriv('aes-256-gcm', aesKey, encrypted.iv);
  decipher.setAuthTag(authTag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}

// Node's WebCrypto/crypto module wants SPKI DER, not a raw point — these two
// helpers convert to/from the raw X9.63 point format that iOS's
// SecKeyCopyExternalRepresentation produces, so the wire format matches
// what the app sends without needing a JS-side ASN.1 library.
const P256_SPKI_PREFIX = Buffer.from(
  '3059301306072a8648ce3d020106082a8648ce3d030107034200',
  'hex'
);

function ecPointToDer(rawPoint) {
  return Buffer.concat([P256_SPKI_PREFIX, rawPoint]);
}

function exportRawPoint(publicKey) {
  const der = publicKey.export({ format: 'der', type: 'spki' });
  return der.subarray(der.length - 65); // strip the fixed SPKI header, keep 0x04||X||Y
}
