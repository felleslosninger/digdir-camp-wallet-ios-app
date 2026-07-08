import crypto from 'node:crypto';

const P256_SPKI_PREFIX = Buffer.from(
  '3059301306072a8648ce3d020106082a8648ce3d030107034200',
  'hex'
);

// RFC 7638 JWK Thumbprint: a canonical, deterministic hash of a public key
// used purely as a compact "commitment" — the server can pin a key's
// identity (via this hash) before ever seeing the key's full disclosure.
// Canonical form is a JSON object with ONLY these members, in this exact
// lexicographic order (crv, kty, x, y) and no extra whitespace.
export function jwkThumbprint({ crv, kty, x, y }) {
  const canonical = JSON.stringify({ crv, kty, x, y });
  return crypto.createHash('sha256').update(canonical, 'utf8').digest('base64url');
}

export function jwkToPublicKey({ x, y }) {
  const xBuf = Buffer.from(x, 'base64url');
  const yBuf = Buffer.from(y, 'base64url');
  const uncompressedPoint = Buffer.concat([Buffer.from([0x04]), xBuf, yBuf]);
  return crypto.createPublicKey({
    key: Buffer.concat([P256_SPKI_PREFIX, uncompressedPoint]),
    format: 'der',
    type: 'spki',
  });
}

export function jwkToRawPoint({ x, y }) {
  return Buffer.concat([Buffer.from([0x04]), Buffer.from(x, 'base64url'), Buffer.from(y, 'base64url')]);
}

// Inverse of the above: rebuilds a usable public key object from the raw
// X9.63 point bytes we store in the database (as opposed to a JWK), e.g.
// for verifying a fetch-challenge signature against a pinned
// `holder_binding_public_key` column.
export function rawPointToPublicKey(point) {
  return crypto.createPublicKey({
    key: Buffer.concat([P256_SPKI_PREFIX, point]),
    format: 'der',
    type: 'spki',
  });
}
