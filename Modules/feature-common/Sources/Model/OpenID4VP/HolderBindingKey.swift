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

/// A SEPARATE Secure Enclave key from `SecureEnclaveMessagingKey`.
/// `SecureEnclaveMessagingKey` does key agreement/ECDH for decrypting messages.
/// This one does signing for holder binding, proof-of-possession, and fetch
/// challenge signatures.
public enum HolderBindingKey {

  private static let keychainService = "no.digdir.eudiwallet.inbox-e2ee"
  private static let keychainAccount = "holder-binding-key"

  public enum KeyError: Error {
    case unavailable
  }

  public static func getOrCreatePrivateKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
    print("[HolderBindingKey] getOrCreatePrivateKey started")

    if let existing = try loadPrivateKey() {
      print("[HolderBindingKey] Existing Secure Enclave signing key loaded from Keychain")
      return existing
    }               

    print("[HolderBindingKey] No existing signing key found")
    print("[HolderBindingKey] SecureEnclave.isAvailable = \(SecureEnclave.isAvailable)")

    guard SecureEnclave.isAvailable else {
      print("[HolderBindingKey] ERROR: Secure Enclave is not available")
      throw KeyError.unavailable
    }

    guard let accessControl = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      [.privateKeyUsage],
      nil
    ) else {
      print("[HolderBindingKey] ERROR: Could not create access control")
      throw KeyError.unavailable
    } 

    do {
      print("[HolderBindingKey] Creating Secure Enclave P-256 signing key")
      let privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)

      print("[HolderBindingKey] Signing key created")
      print("[HolderBindingKey] Saving signing key handle to Keychain")
      try save(dataRepresentation: privateKey.dataRepresentation)

      print("[HolderBindingKey] Signing key handle saved successfully")
      return privateKey
    } catch {
      print("[HolderBindingKey] ERROR while creating/saving signing key: \(error)")
      throw KeyError.unavailable
    }
  }

  /// Builds and signs a Key Binding JWT binding this PID presentation to:
  /// - aud: verifier client_id
  /// - nonce: verifier nonce
  /// - sd_hash: disclosed credential hash
  public static func buildKeyBindingJWT(
    audience: String,
    nonce: String,
    sdHash: String
  ) throws -> String {
    print("[HolderBindingKey] buildKeyBindingJWT started")
    print("[HolderBindingKey] audience: \(audience)")
    print("[HolderBindingKey] nonce: \(nonce)")

    let payload: [String: Any] = [
      "aud": audience,
      "nonce": nonce,
      "sd_hash": sdHash
    ]

    let jwt = try buildSelfSignedJWT(payload: payload)

    print("[HolderBindingKey] buildKeyBindingJWT success")
    return jwt
  }

  /// Builds a Proof-of-Possession JWT for the final registration step.
  public static func buildProofOfPossessionJWT(sessionToken: String) throws -> String {
    print("[HolderBindingKey] buildProofOfPossessionJWT started")

    let payload: [String: Any] = [
      "sub": sessionToken,
      "jti": UUID().uuidString
    ]

    let jwt = try buildSelfSignedJWT(payload: payload)

    print("[HolderBindingKey] buildProofOfPossessionJWT success")
    return jwt
  }

  /// Raw signature over a fetch challenge nonce.
  public static func sign(nonce: String) throws -> String {
    print("[HolderBindingKey] sign challenge started")

    let privateKey = try getOrCreatePrivateKey()
    let signature = try privateKey.signature(for: Data(nonce.utf8))
    let encoded = signature.rawRepresentation.base64URLEncodedString()

    print("[HolderBindingKey] sign challenge success")
    return encoded
  }

  private static func buildSelfSignedJWT(payload: [String: Any]) throws -> String {
    print("[HolderBindingKey] buildSelfSignedJWT started")

    let privateKey = try getOrCreatePrivateKey()

    let publicKeyData = privateKey.publicKey.rawRepresentation
    print("[HolderBindingKey] raw public key length = \(publicKeyData.count)")

    let coordinates = try extractP256Coordinates(from: publicKeyData)

    let header: [String: Any] = [
      "typ": "kb+jwt",
      "alg": "ES256",
      "jwk": [
        "kty": "EC",
        "crv": "P-256",
        "x": coordinates.x.base64URLEncodedString(),
        "y": coordinates.y.base64URLEncodedString()
      ]
    ]

    var fullPayload = payload
    fullPayload["iat"] = Int(Date().timeIntervalSince1970)

    let encodedHeader = try base64URL(header)
    let encodedPayload = try base64URL(fullPayload)
    let signingInput = "\(encodedHeader).\(encodedPayload)"

    print("[HolderBindingKey] signing input created")

    let signature = try privateKey.signature(for: Data(signingInput.utf8))
    let encodedSignature = signature.rawRepresentation.base64URLEncodedString()

    print("[HolderBindingKey] buildSelfSignedJWT success")

    return "\(signingInput).\(encodedSignature)"
  }

  // MARK: - Helpers

  private static func extractP256Coordinates(from publicKeyData: Data) throws -> (x: Data, y: Data) {
    let bytes = Array(publicKeyData)

    if bytes.count == 65 && bytes.first == 0x04 {
      let x = Data(bytes[1..<33])
      let y = Data(bytes[33..<65])

      print("[HolderBindingKey] Extracted coordinates from 65-byte X9.63 public key")
      return (x, y)
    }

    if bytes.count == 64 {
      let x = Data(bytes[0..<32])
      let y = Data(bytes[32..<64])

      print("[HolderBindingKey] Extracted coordinates from 64-byte raw public key")
      return (x, y)
    }

    print("[HolderBindingKey] ERROR: Unexpected public key length = \(bytes.count)")
    throw KeyError.unavailable
  }

  // MARK: - Keychain persistence

  private static func save(dataRepresentation: Data) throws {
    print("[HolderBindingKey] save started. Data length = \(dataRepresentation.count)")

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount
    ]

    SecItemDelete(query as CFDictionary)

    var attributes = query
    attributes[kSecValueData as String] = dataRepresentation
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    let status = SecItemAdd(attributes as CFDictionary, nil)

    guard status == errSecSuccess else {
      print("[HolderBindingKey] ERROR: SecItemAdd failed. Status = \(status)")
      throw KeyError.unavailable
    }

    print("[HolderBindingKey] save success")
  }

  private static func loadPrivateKey() throws -> SecureEnclave.P256.Signing.PrivateKey? {
    print("[HolderBindingKey] loadPrivateKey started")

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
      print("[HolderBindingKey] No signing key found in Keychain")
      return nil
    }

    guard status == errSecSuccess, let data = result as? Data else {
      print("[HolderBindingKey] Keychain lookup failed. Status = \(status)")
      return nil
    }

    do {
      let privateKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
      print("[HolderBindingKey] loadPrivateKey success")
      return privateKey
    } catch {
      print("[HolderBindingKey] ERROR: Could not recreate Secure Enclave signing key: \(error)")
      return nil
    }
  }

  private static func base64URL(_ jsonObject: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: jsonObject,
      options: [.sortedKeys]
    )

    return data.base64URLEncodedString()
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
