import { db } from '../db/index.js';
import { hmac } from '../crypto/index.js';

// Resolves the calling sender (agency) from an API key, so that
// `sender_id` on a stored message always reflects who was ACTUALLY
// authenticated — never a value the caller typed into the request body.
// A revoked or unknown key is rejected before touching anything else.
export function authenticateSender(req, res, next) {
  const authHeader = req.headers.authorization || '';
  const apiKey = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : null;
  if (!apiKey) {
    return res.status(401).json({ error: 'Missing Authorization: Bearer <api_key> header' });
  }

  const sender = db.prepare(
    'SELECT id, name FROM sender WHERE api_key_hash = ? AND revoked_at IS NULL'
  ).get(hmac(apiKey));

  if (!sender) {
    return res.status(401).json({ error: 'Invalid or revoked API key' });
  }

  req.sender = sender; // { id, name }
  next();
}
