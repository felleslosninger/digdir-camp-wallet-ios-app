import crypto from 'node:crypto';
import { HMAC_KEY, AES_KEY } from './keys.js';

// Deterministic keyed hash — used so we can look up a row (e.g. "does this
// PID already have a registration?") WITHOUT ever storing the PID itself.
export function hmac(value) {
  return crypto.createHmac('sha256', HMAC_KEY).update(value, 'utf8').digest();
}

export function encrypt(plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', AES_KEY, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return { ciphertext: Buffer.concat([ciphertext, authTag]), iv };
}

export function decrypt(ciphertextWithTag, iv) {
  const authTag = ciphertextWithTag.subarray(ciphertextWithTag.length - 16);
  const ciphertext = ciphertextWithTag.subarray(0, ciphertextWithTag.length - 16);
  const decipher = crypto.createDecipheriv('aes-256-gcm', AES_KEY, iv);
  decipher.setAuthTag(authTag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}

export function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('base64url');
}

export function timingSafeEqualHex(a, b) {
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}
