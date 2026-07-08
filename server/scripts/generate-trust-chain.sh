#!/usr/bin/env bash
# Regenerates the local trust chain used to sign OpenID4VP Request Objects
# (client_id_scheme: x509_san_dns). The private keys are gitignored on
# purpose (server/trust-chain/*-key.pem) — anyone cloning this repo must run
# this script once before the server can start. The public certs
# (root-ca-cert.pem, verifier-cert.pem) ARE committed, purely so
# TrustAnchorRegistry.swift's pinned cert (base64) can be regenerated to
# match if needed — but the CERTS this script produces will have a fresh
# random keypair each time you run it, so if you re-run it you must also
# update the base64 pinned in TrustAnchorRegistry.swift.
set -euo pipefail
cd "$(dirname "$0")/../trust-chain"

if [ -f verifier-key.pem ]; then
  echo "trust-chain already exists (verifier-key.pem found) — delete this directory's *.pem/*.srl first if you really want to regenerate it."
  exit 1
fi

# 1. Root CA — stands in for a national/EU Trust Anchor (e.g. an EU LOTL entry)
openssl ecparam -name prime256v1 -genkey -noout -out root-ca-key.pem
openssl req -x509 -new -key root-ca-key.pem -sha256 -days 3650 \
  -subj "/CN=Digdir Camp Trust Anchor Root/O=Digdir/C=NO" \
  -out root-ca-cert.pem

# 2. Leaf "verifier" cert for this backend. SAN dNSName MUST match
# VERIFIER_CLIENT_ID in src/crypto/requestObject.js.
openssl ecparam -name prime256v1 -genkey -noout -out verifier-key.pem
openssl req -new -key verifier-key.pem \
  -subj "/CN=inbox-backend.example/O=Digdir/C=NO" \
  -out verifier-csr.pem

openssl x509 -req -in verifier-csr.pem -CA root-ca-cert.pem -CAkey root-ca-key.pem \
  -CAcreateserial -days 825 -sha256 -extfile verifier-ext.cnf -out verifier-cert.pem

rm -f verifier-csr.pem

echo
echo "Trust chain generated. If root-ca-cert.pem changed, update the pinned"
echo "base64 in Modules/feature-common/Sources/Model/OpenID4VP/TrustAnchorRegistry.swift:"
echo
openssl x509 -in root-ca-cert.pem -outform DER | base64
