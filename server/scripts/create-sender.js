#!/usr/bin/env node
// Provisions a new sender (agency) and prints a fresh API key ONCE.
// Only the HMAC of the key is stored — if this output is lost, there is no
// way to recover the raw key; run this script again to issue a new one
// (revoke the old sender row first if replacing, not adding, an agency).
//
// Usage: node scripts/create-sender.js "nav"
import 'dotenv/config';
import crypto from 'node:crypto';
import { db } from '../src/db/index.js';
import { hmac, randomToken } from '../src/crypto/index.js';

const name = process.argv[2];
if (!name) {
  console.error('Usage: node scripts/create-sender.js <sender-name>');
  process.exit(1);
}

const existing = db.prepare('SELECT id FROM sender WHERE name = ? AND revoked_at IS NULL').get(name);
if (existing) {
  console.error(`A sender named "${name}" already has an active API key. Revoke it first if you want to replace it:`);
  console.error(`  UPDATE sender SET revoked_at = datetime('now') WHERE name = '${name}';`);
  process.exit(1);
}

const apiKey = randomToken(32);
const id = crypto.randomUUID();

db.prepare(`
  INSERT INTO sender (id, name, api_key_hash, created_at)
  VALUES (?, ?, ?, ?)
`).run(id, name, hmac(apiKey), new Date().toISOString());

console.log(`Sender "${name}" created (id: ${id}).`);
console.log();
console.log('API key (shown ONCE — store it now, e.g. in the sender\'s own secrets manager):');
console.log();
console.log(`  ${apiKey}`);
console.log();
console.log('Usage from the sender\'s side:');
console.log(`  curl -X POST http://localhost:3001/messages/send \\`);
console.log(`    -H "Authorization: Bearer ${apiKey}" \\`);
console.log(`    -H "Content-Type: application/json" \\`);
console.log(`    -d '{"pid":"...", "plaintext":"..."}'`);
