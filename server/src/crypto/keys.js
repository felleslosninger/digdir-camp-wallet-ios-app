import crypto from 'node:crypto';

// In this prototype the keys come from env vars (base64). In production
// these must live in a KMS/HSM, never in application config or the DB.
function requireKey(envVar, byteLength) {
  const value = process.env[envVar];
  if (!value) {
    throw new Error(
      `Missing ${envVar}. Generate one with: node -e "console.log(require('crypto').randomBytes(${byteLength}).toString('base64'))"`
    );
  }
  const buf = Buffer.from(value, 'base64');
  if (buf.length !== byteLength) {
    throw new Error(`${envVar} must decode to exactly ${byteLength} bytes`);
  }
  return buf;
}

export const HMAC_KEY = requireKey('SERVER_HMAC_KEY', 32);
export const AES_KEY = requireKey('SERVER_AES_KEY', 32);
export const SESSION_JWT_SECRET = requireKey('SERVER_SESSION_SECRET', 32);
