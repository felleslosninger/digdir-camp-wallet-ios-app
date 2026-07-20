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

/// Owns the device's P-256 messaging keypair. The private key is generated
/// INSIDE the Secure Enclave and never exists outside it in any exportable
/// form — `SecureEnclave.P256.KeyAgreement.PrivateKey` is a handle, not key
/// material. This is what makes server-side compromise harmless: even a
/// full database dump only ever contains the public key.
///
/// Only P-256 is supported here because the Secure Enclave does not support
/// Ed25519 — key agreement (ECDH) on-device requires P-256.
public enum SecureEnclaveMessagingKey {

  private static let keychainTag = "no.digdir.eudiwallet.inbox-e2ee.device-key".data(using: .utf8)!

  public enum KeyError: Error {
    case unavailable
    case decryptionFailed
  }

  /// Generates the keypair once per install and persists the Secure Enclave
  /// handle in the Keychain (not the key itself — SE keys never leave the
  /// chip). Idempotent: returns the existing key if one is already there.
  public static func getOrCreatePrivateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
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

    let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: accessControl)
    try save(dataRepresentation: privateKey.dataRepresentation)
    return privateKey
  }

  /// The public key to hand to the backend during OpenID4VP key-binding.
  /// Encoded as the raw X9.63 uncompressed point (0x04 || X || Y) — the same
  /// wire format the server's `ecies.js` expects, so no ASN.1 wrangling is
  /// needed on either side.
  public static func publicKeyForKeyBinding() throws -> Data {
    try getOrCreatePrivateKey().publicKey.rawRepresentation
  }

  public struct JWK: Encodable {
    public let crv = "P-256"
    public let kty = "EC"
    public let x: String
    public let y: String
  }

  /// The public key as a JWK — the format the registration step
  /// (`POST /keybinding/register`) and RFC 7638 thumbprinting both expect.
  public static func publicKeyJWK() throws -> JWK {
    let point = try publicKeyForKeyBinding()
    let x = point[1..<33]
    let y = point[33..<65]
    return JWK(x: Data(x).base64URLEncodedString(), y: Data(y).base64URLEncodedString())
  }

  /// RFC 7638 JWK Thumbprint: a compact, deterministic hash of the public
  /// key. Committed to the backend BEFORE any OpenID4VP presentation
  /// happens (`POST /keybinding/start`), so the server knows exactly which
  /// key it expects long before it sees the actual key disclosed at
  /// registration time. Member order and exact JSON serialization (no
  /// whitespace) are fixed by the spec — this must byte-for-byte match
  /// what `jwk.js` on the server computes.
  public static func publicKeyThumbprint() throws -> String {
    let jwk = try publicKeyJWK()
    let canonical = "{\"crv\":\"\(jwk.crv)\",\"kty\":\"\(jwk.kty)\",\"x\":\"\(jwk.x)\",\"y\":\"\(jwk.y)\"}"
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return Data(digest).base64URLEncodedString()
  }

  /// Performs ECDH against a sender's one-time ephemeral public key, derives
  /// the same AES-256-GCM key the sender used (via HKDF with the salt they
  /// sent), and decrypts. This never leaves the device — the Secure Enclave
  /// performs the ECDH step internally without ever exposing the private
  /// scalar to the app process.
  public static func decrypt(
    ciphertextWithTag: Data,
    iv: Data,
    hkdfSalt: Data,
    senderEphemeralPublicKey: Data
  ) throws -> String {
    let privateKey = try getOrCreatePrivateKey()
    let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: senderEphemeralPublicKey)

    let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
    let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: hkdfSalt,
      sharedInfo: Data("inbox-e2ee-v1".utf8),
      outputByteCount: 32
    )

    // AES.GCM.SealedBox wants nonce + ciphertext + tag split out; our wire
    // format (matching ecies.js) appends the 16-byte tag to the ciphertext.
    let tag = ciphertextWithTag.suffix(16)
    let ciphertext = ciphertextWithTag.dropLast(16)
    let nonce = try AES.GCM.Nonce(data: iv)
    let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

    guard let plaintext = String(data: try AES.GCM.open(sealedBox, using: symmetricKey), encoding: .utf8) else {
      throw KeyError.decryptionFailed
    }
    return plaintext
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

  private static func loadPrivateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrApplicationTag as String: keychainTag,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
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
