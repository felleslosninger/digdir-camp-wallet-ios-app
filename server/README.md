# E2EE inbox relay (prototype)

The server is a **blind relay**: it never sees a message in plaintext, never
holds a key capable of decrypting one, and only authenticates requests via
fresh signatures — never a reusable bearer token. It also merges in real
APNs push delivery, ported from the standalone `digdir-wallet-messaging-backend`
prototype (see "Relationship to digdir-wallet-messaging-backend" below).

## Flow 1 — Subscribe (key binding)

1. **Commit** (`POST /keybinding/start`) — the app computes an RFC 7638
   thumbprint of its Secure Enclave ECDH public key
   (`SecureEnclaveMessagingKey.swift`) and sends ONLY that thumbprint, before
   any credential presentation happens. The server bakes it into the
   OpenID4VP request's nonce as `"<uuid>.<thumbprint>"`, and returns a
   `request_uri` (Request by Reference) instead of the request itself.
2. **Present** (`POST /keybinding/callback`) — the app fetches + verifies the
   signed Request Object (`x509_san_dns` chain check against a pinned Trust
   Anchor, see `src/crypto/requestObject.js` and
   `OpenID4VPRequestVerifier.swift`), presents its PID, and signs a Key
   Binding JWT over that nonce with a SEPARATE Secure Enclave signing key
   (`HolderBindingKey.swift`). On success the server hands back a
   single-use `session_token` — nothing is registered yet.
3. **Register** (`POST /keybinding/register`) — the app sends its actual
   public key (as a JWK) plus a FRESH Proof-of-Possession JWT signed over
   that `session_token`. The server cross-checks the JWK's thumbprint
   against what was committed in step 1, verifies the fresh signature, and
   only then persists `pid_hash -> device_public_key` — also pinning the
   holder-binding public key for later use in Flow 2.

**Mocked:** the actual vp_token / PID issuer signature chain
(`mock_pid` in the callback body stands in for it) — no real PID issuer
integration here.

## Flow 2 — Fetch (retrieve + decrypt a message)

0. **Authenticate the sender** — `POST /messages/send` requires
   `Authorization: Bearer <api_key>` (`src/middleware/senderAuth.js`).
   Provision a key with `node scripts/create-sender.js <name>` (prints the
   raw key ONCE — only its hash is stored). `sender_id` on a stored message
   always comes from this authenticated identity, never from the request
   body, so no caller can claim to be an agency it isn't. Rate-limited to
   60 requests/minute per key (`express-rate-limit`).
1. **Send** (`POST /messages/send`) — the sender (e.g. NAV) encrypts
   client-side using ECIES: fresh ephemeral P-256 keypair → ECDH against the
   recipient's registered public key → HKDF-SHA256 → AES-256-GCM
   (`src/crypto/ecies.js`). A SHA-256 hash of the original plaintext is also
   recorded (`content_hash` — proof-of-content, not a decryption aid; see
   inline comments in `schema.sql`). Only ciphertext + hash + the one-time
   ephemeral public key reach this server. A generic APNs push
   (`src/push/apns.js`) then notifies the device — the same fixed alert
   text every time ("Ny melding i lommeboken"), never derived from the
   actual sender or content, so the user sees a real visible notification
   without Apple (or anyone intercepting the push) learning anything
   message-specific.
2. **Challenge** (`GET /messages/challenge/:registrationId`) — the device
   asks for a fresh, single-use nonce.
3. **Fetch** (`POST /messages/fetch`) — the device signs that nonce with its
   holder-binding key and submits the signature. Only after that verifies
   against the pinned key from registration does the server hand back
   ciphertext. The device then repeats the ECDH step with its Secure
   Enclave messaging key to derive the same AES key and decrypts locally.

## Run it

```bash
cd server
npm install
cp .env.example .env   # fill in SERVER_HMAC_KEY / SERVER_AES_KEY / SERVER_SESSION_SECRET
                        # (generate each with: node -e "console.log(require('crypto').randomBytes(32).toString('base64'))")
./scripts/generate-trust-chain.sh   # REQUIRED on a fresh clone — see below
npm start
```

APNs push requires a real `.p8` key (see `.env.example`) — without one,
`/messages/send` still stores the message and reports
`"pushDelivery": "failed"` instead of losing the message.

### Trust chain setup (required on a fresh clone)

`server/trust-chain/*-key.pem` are gitignored on purpose — only the public
certs are committed. Run `./scripts/generate-trust-chain.sh` once; it
refuses to overwrite an existing chain. This generates a **new** keypair
each time, which means it won't match the Trust Anchor already pinned in
`Modules/feature-common/Sources/Model/OpenID4VP/TrustAnchorRegistry.swift`
(that one matches whoever originally generated the committed certs). The
script prints the new root cert's base64 at the end — paste it into
`TrustAnchorRegistry.swift`'s `pinnedRootCertificatesBase64` to keep the
app and server in sync, or ask whoever has the original private keys to
share them out-of-band instead of regenerating.

## Verified manually (see conversation)

Full round trip tested via curl + Node's `crypto` module standing in for the
device, for both flows, including simulated attacks that were correctly
rejected: replayed/reused session tokens and challenges, a swapped-in key
that didn't match what was committed, and a signature from the wrong key.

## Relationship to `digdir-wallet-messaging-backend`

That's a separate, earlier prototype (real APNs push, no PID binding, no
encryption, broadcasts every message to every registered device) that
`Wallet/MessagingBackend.swift` and `InboxTabViewModel.swift` originally
pointed to. This server absorbs its push-delivery role
(`src/push/apns.js`, ported with one change: the original sent the
message's actual title/body in the push alert, which would leak content
through Apple's push servers — this version sends the same fixed, generic
alert text every time instead) while adding the PID binding and E2EE it
lacked.
This server defaults to port 3001 (not 3000) specifically to avoid that
collision — see `.env.example`.

## What's still a prototype, not production

- OpenID4VP presentation + Key Binding JWT verification is mocked
  (`mock_pid`); the holder-binding public key is accepted self-asserted at
  registration time (trust-on-first-use) rather than anchored in the PID
  credential's own `cnf` claim at issuance.
- No dedicated push-token-refresh endpoint (would sign a fresh challenge
  instead of repeating the whole key-binding ceremony).
- No message expiry/deletion policy.
- Keys come from `.env`, not a KMS. Sender API keys are provisioned by
  hand via a script, not a real onboarding/admin flow.
