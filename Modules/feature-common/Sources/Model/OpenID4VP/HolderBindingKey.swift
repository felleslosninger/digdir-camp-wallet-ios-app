/*
 * Copyright (c) 2026 European Commission
 *
 * Licensed under the EUPL, Version 1.2 or - as soon they will be approved by the European
 * Commission - subsequent versions of the EUPL (the "Licence"); You may not use this work
 * except in compliance with the Licence.
 *
 * You may obtain a copy of the Licence at:
 * https://joinup.ec.europa.eu/software/page/eupl
 *
 * Unless required by applicable law or agreed to in writing, software distributed under
 * the Licence is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF
 * ANY KIND, either express or implied. See the Licence for the specific language
 * governing permissions and limitations under the Licence.
 */
import Foundation
import CryptoKit
import Security

/// A SEPARATE Secure Enclave key from `SecureEnclaveMessagingKey`. That one
/// does key AGREEMENT (ECDH, for decrypting messages); this one does
/// SIGNING (proving possession, for Holder Binding). The Secure Enclave
/// issues each key for a single purpose — a key created for one cannot be
/// (re)used for the other, and keeping them separate also means a bug or
/// compromise in one code path can't be repurposed to abuse the other.
///
/// "Holder Binding" is what stops a stolen/copied Verifiable Presentation
/// from being replayed by someone else: the Verifier's `nonce` is signed
/// into a Key Binding JWT (KB-JWT) using a private key that exists ONLY on
/// this phone's Secure Enclave. A verifier that checks this signature knows
/// the presentation could only have been produced by the device holding
/// that specific hardware key — not copied and replayed from a network
/// capture or a phished screenshot.
public enum HolderBindingKey {

  private static let keychainTag = "no.digdir.eudiwallet.inbox-e2ee.holder-binding-key".data(using: .utf8)!

  public enum KeyError: Error {
    case unavailable
  }

  public static func getOrCreatePrivateKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
    if let existing = try loadPrivateKey() {
      return existing
    }
    guard SecureEnclave.isAvailable else { throw KeyError.unavailable }

    let accessControl = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      [.privateKeyUsage],
      nil
    )!

    let privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
    try save(dataRepresentation: privateKey.dataRepresentation)
    return privateKey
  }

  /// Builds and signs a Key Binding JWT binding this PID presentation to:
  /// - `aud`: the verifier's client_id (so it can't be replayed against a
  ///   different verifier),
  /// - `nonce`: the verified Request Object's nonce — which already has the
  ///   messaging key's RFC 7638 thumbprint baked into it
  ///   (`"<uuid>.<thumbprint>"`, committed via `/keybinding/start` BEFORE
  ///   this presentation happened). Signing over it here proves the PID
  ///   holder consents to binding their identity to that already-committed
  ///   key, without this JWT needing to carry the raw key itself,
  /// - `sdHash`: a hash of the disclosed SD-JWT credential contents (so the
  ///   signature is bound to exactly what was disclosed, not swappable).
  ///
  /// Simplification vs. the real SD-JWT VC spec: a production wallet's
  /// holder-binding public key would already be anchored in the PID
  /// credential itself (issued into a `cnf` claim at PID issuance time), so
  /// the verifier trusts it via the PID issuer's signature. This prototype
  /// has no real PID issuance step, so it self-asserts the holder-binding
  /// public key inline in the JWT header (`jwk`) — trust-on-first-use, only
  /// good enough to demonstrate the signing mechanism itself.
  public static func buildKeyBindingJWT(audience: String, nonce: String, sdHash: String) throws -> String {
    let payload: [String: Any] = ["aud": audience, "nonce": nonce, "sd_hash": sdHash]
    return try buildSelfSignedJWT(payload: payload)
  }

  /// Builds a Proof-of-Possession JWT for the FINAL registration step
  /// (`POST /keybinding/register`), completely decoupled from the OpenID4VP
  /// presentation: it signs over a single-use `sessionToken` issued after
  /// the presentation succeeded. A captured `sessionToken` alone is useless
  /// to an attacker without ALSO being able to produce this fresh
  /// signature — i.e. without holding this Secure Enclave key right now.
  public static func buildProofOfPossessionJWT(sessionToken: String) throws -> String {
    let payload: [String: Any] = ["sub": sessionToken, "jti": UUID().uuidString]
    return try buildSelfSignedJWT(payload: payload)
  }

  /// Raw signature over a fetch challenge nonce — no JWT wrapping needed
  /// here, since by this point the server already has our holder-binding
  /// public key PINNED from registration (see `/keybinding/register`), so
  /// there's nothing left to self-assert. Just prove fresh possession.
  public static func sign(nonce: String) throws -> String {
    let privateKey = try getOrCreatePrivateKey()
    let signature = try privateKey.signature(for: Data(nonce.utf8))
    return signature.rawRepresentation.base64URLEncodedString()
  }

  private static func buildSelfSignedJWT(payload: [String: Any]) throws -> String {
    let privateKey = try getOrCreatePrivateKey()
    let publicKeyPoint = privateKey.publicKey.rawRepresentation // 0x04 || X || Y, 65 bytes for P-256
    let x = publicKeyPoint[1..<33]
    let y = publicKeyPoint[33..<65]

    let header: [String: Any] = [
      "typ": "kb+jwt",
      "alg": "ES256",
      "jwk": ["kty": "EC", "crv": "P-256", "x": Data(x).base64URLEncodedString(), "y": Data(y).base64URLEncodedString()]
    ]
    var fullPayload = payload
    fullPayload["iat"] = Int(Date().timeIntervalSince1970)

    let signingInput = "\(try base64URL(header)).\(try base64URL(fullPayload))"
    let signature = try privateKey.signature(for: Data(signingInput.utf8))

    // .rawRepresentation is exactly the r||s (64-byte) format JWS ES256
    // expects — the same format the server-side verifier reads back.
    return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
  }

  // MARK: - Keychain persistence of the Secure Enclave key handle

  private static func save(dataRepresentation: Data) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrApplicationTag as String: keychainTag
    ]
    SecItemDelete(query as CFDictionary)

    var attributes = query
    attributes[kSecValueData as String] = dataRepresentation
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeyError.unavailable }
  }

  private static func loadPrivateKey() throws -> SecureEnclave.P256.Signing.PrivateKey? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrApplicationTag as String: keychainTag,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
  }

  private static func base64URL(_ jsonObject: [String: Any]) throws -> String {
    try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]).base64URLEncodedString()
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
