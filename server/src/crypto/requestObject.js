import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TRUST_CHAIN_DIR = path.join(__dirname, '../../trust-chain');

// The verifier's own identity, per OpenID4VP `client_id_scheme: x509_san_dns`.
// client_id MUST equal a dNSName SAN entry in the leaf certificate below —
// that's the whole trust mechanism: "I am whoever this certificate, signed
// by a chain up to a trust anchor you recognize, says I am."
export const VERIFIER_CLIENT_ID = 'inbox-backend.example';

const verifierKeyPem = fs.readFileSync(path.join(TRUST_CHAIN_DIR, 'verifier-key.pem'), 'utf8');
const verifierCertPem = fs.readFileSync(path.join(TRUST_CHAIN_DIR, 'verifier-cert.pem'), 'utf8');
const rootCertPem = fs.readFileSync(path.join(TRUST_CHAIN_DIR, 'root-ca-cert.pem'), 'utf8');

function pemToDerBase64(pem) {
  return pem
    .replace(/-----BEGIN CERTIFICATE-----/, '')
    .replace(/-----END CERTIFICATE-----/, '')
    .replace(/\s+/g, '');
}

function base64url(input) {
  return Buffer.from(input).toString('base64url');
}

// Builds a signed OpenID4VP "Request Object" — a JWT whose header carries
// the full certificate chain (x5c) up to (but not including) the trust
// anchor. The wallet verifies this chain against ITS OWN pinned trust
// anchor list before trusting anything in the payload.
export function buildSignedRequestObject({ nonce, state, responseUri, presentationDefinition }) {
  const header = {
    alg: 'ES256',
    typ: 'oauth-authz-req+jwt',
    x5c: [pemToDerBase64(verifierCertPem)], // leaf only; root is the wallet's own pinned anchor, not sent
  };

  const payload = {
    client_id: VERIFIER_CLIENT_ID,
    client_id_scheme: 'x509_san_dns',
    response_uri: responseUri,
    response_mode: 'direct_post',
    response_type: 'vp_token',
    nonce,
    state,
    presentation_definition: presentationDefinition,
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 300,
  };

  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;

  // 'ieee-p1363' gives the raw r||s signature format JWS expects (64 bytes
  // for P-256), instead of Node's default ASN.1 DER encoding.
  const signature = crypto.sign('sha256', Buffer.from(signingInput), {
    key: verifierKeyPem,
    dsaEncoding: 'ieee-p1363',
  });

  return `${signingInput}.${signature.toString('base64url')}`;
}

// Exposed so the wallet-side README/tests can pin the exact same root the
// server trusts about itself — in a real deployment this list would ship
// in the app (or be fetched from a signed, out-of-band trust list like the
// EU LOTL), never from this server.
export function getRootCaCertificatePem() {
  return rootCertPem;
}
