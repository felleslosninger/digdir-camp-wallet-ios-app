-- E2EE schema. The server is a blind relay: it stores ciphertext and public
-- keys only. It never sees a message in plaintext and never holds a private
-- key capable of decrypting anything.

CREATE TABLE IF NOT EXISTS inbox_registration (
    id                          TEXT PRIMARY KEY,           -- uuid
    pid_hash                    BLOB NOT NULL UNIQUE,        -- HMAC-SHA256(pid, SERVER_HMAC_KEY)
    device_public_key           BLOB NOT NULL,                -- ECDH (messaging) P-256 public key, X9.63 uncompressed point
    holder_binding_public_key   BLOB NOT NULL,                -- SEPARATE signing P-256 public key, pinned at registration time — used to authenticate later fetch requests
    fcm_token_encrypted         BLOB NOT NULL,                -- AES-256-GCM(fcm_token) — only for silent-push delivery, not message content
    fcm_token_iv                BLOB NOT NULL,
    fcm_token_hash              BLOB NOT NULL,
    device_id                   TEXT NOT NULL,
    created_at                  TEXT NOT NULL,
    updated_at                  TEXT NOT NULL,
    last_verified_at            TEXT NOT NULL,                -- last successful OpenID4VP key-binding
    revoked_at                  TEXT
);

CREATE INDEX IF NOT EXISTS idx_fcm_token_hash ON inbox_registration (fcm_token_hash);

-- Short-lived state for an in-progress key-binding ceremony (before PID is
-- known). Holds the OpenID4VP request nonce and the not-yet-bound FCM
-- token. Never contains the PID. `key_thumbprint` is committed by the app
-- BEFORE the presentation happens (baked into `nonce`), so the server
-- already knows which key it expects before it ever sees the disclosure.
CREATE TABLE IF NOT EXISTS activation_session (
    state               TEXT PRIMARY KEY,
    nonce                TEXT NOT NULL,           -- "<uuid>.<key_thumbprint>" — bound into the Request Object AND the Key Binding JWT
    key_thumbprint       TEXT NOT NULL,            -- RFC 7638 JWK thumbprint, committed before presentation
    fcm_token            TEXT NOT NULL,
    device_id            TEXT NOT NULL,
    created_at           TEXT NOT NULL,
    expires_at           TEXT NOT NULL
);

-- Single-use bridge between "PID presentation succeeded" and "device
-- finished registering its messaging key". Deliberately short-lived and
-- consumed on first use, so a captured session_token from the redirect URL
-- is useless without ALSO producing a fresh signature (pop_jwt) over it.
CREATE TABLE IF NOT EXISTS pending_registration (
    session_token       TEXT PRIMARY KEY,
    pid_hash             BLOB NOT NULL,
    committed_thumbprint TEXT NOT NULL,
    fcm_token            TEXT NOT NULL,
    device_id            TEXT NOT NULL,
    created_at           TEXT NOT NULL,
    expires_at           TEXT NOT NULL
);

-- One row per authorized sender (agency). `api_key_hash` is HMAC-SHA256 of
-- the raw API key — the raw key is shown to the sender ONCE at creation
-- time (see scripts/create-sender.js) and never stored or logged again.
-- `sender_id` on a message always comes from THIS table (resolved from the
-- authenticated key), never from the request body — otherwise any caller
-- could claim to be "nav" just by typing it in.
CREATE TABLE IF NOT EXISTS sender (
    id              TEXT PRIMARY KEY,      -- uuid
    name            TEXT NOT NULL UNIQUE,   -- e.g. "nav", "skatteetaten" — shown to the user in the app
    api_key_hash    BLOB NOT NULL UNIQUE,
    created_at      TEXT NOT NULL,
    revoked_at      TEXT
);

-- Encrypted messages. `ciphertext` is opaque to us — AES-256-GCM output
-- (includes the auth tag). `sender_ephemeral_public_key` is the one-time
-- P-256 public key the sender generated for THIS message's ECDH exchange;
-- it is not secret, but MUST be unique per message for forward secrecy.
-- `content_hash` = SHA-256(plaintext), computed by the SENDER before
-- encrypting and stored alongside the ciphertext. Not for confidentiality
-- (it doesn't help decrypt anything) — it exists so that, in a later
-- dispute, someone who reproduces the original plaintext (from the
-- sender's or recipient's own records) can prove it's byte-for-byte what
-- was actually transmitted through us, without us ever having stored or
-- seen the plaintext ourselves. This is what eIDAS-style "proof of
-- content" requires for a registered delivery service, made compatible
-- with E2EE — see conversation for the reasoning. NOT sufficient on its
-- own for formal eIDAS-qualified status (that also needs qualified
-- timestamps, audited processes, supervisory certification, etc.).
CREATE TABLE IF NOT EXISTS message (
    id                          TEXT PRIMARY KEY,
    recipient_registration_id   TEXT NOT NULL REFERENCES inbox_registration(id),
    sender_id                   TEXT NOT NULL,                -- e.g. "nav", "skatteetaten" — for display only, not trust
    ciphertext                  BLOB NOT NULL,
    iv                          BLOB NOT NULL,
    sender_ephemeral_public_key BLOB NOT NULL,                -- P-256 public key, X9.63 uncompressed point
    hkdf_salt                   BLOB NOT NULL,
    content_hash                BLOB NOT NULL,                -- SHA-256(plaintext) — proof-of-content, not a decryption aid
    created_at                  TEXT NOT NULL,
    delivered_at                TEXT,
    read_at                     TEXT
);

CREATE INDEX IF NOT EXISTS idx_message_recipient ON message (recipient_registration_id);

-- Single-use challenge for authenticating a fetch request: the device must
-- sign this exact nonce with its holder-binding private key before the
-- server will hand out ciphertext. Confidentiality (can a bystander read
-- the message?) is handled entirely separately by ECIES in `message` —
-- this table only answers "is this the right device asking?".
CREATE TABLE IF NOT EXISTS fetch_challenge (
    nonce               TEXT PRIMARY KEY,
    registration_id     TEXT NOT NULL REFERENCES inbox_registration(id),
    created_at          TEXT NOT NULL,
    expires_at          TEXT NOT NULL
);
