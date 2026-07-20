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

/// Owns the device's P-256 messaging keypair.
/// The private key is generated inside the Secure Enclave and never leaves
/// the device. The backend only receives the public key / JWK.
public enum SecureEnclaveMessagingKey {

  private static let keychainService = "no.digdir.eudiwallet.inbox-e2ee"
  private static let keychainAccount = "device-key"

  public enum KeyError: Error {
    case unavailable
    case decryptionFailed
  }

  /// Generates the keypair once per install and persists the Secure Enclave
  /// key handle in the Keychain.
  public static func getOrCreatePrivateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
    print("[SecureEnclaveMessagingKey] getOrCreatePrivateKey started")

    if let existing = try loadPrivateKey() {
      print("[SecureEnclaveMessagingKey] Existing Secure Enclave key loaded from Keychain")
      return existing
    }

    print("[SecureEnclaveMessagingKey] No existing key found")
    print("[SecureEnclaveMessagingKey] SecureEnclave.isAvailable = \(SecureEnclave.isAvailable)")

    guard SecureEnclave.isAvailable else {
      print("[SecureEnclaveMessagingKey] ERROR: Secure Enclave is not available")
      throw KeyError.unavailable
    }

    guard let accessControl = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      [.privateKeyUsage],
      nil
    ) else {
      print("[SecureEnclaveMessagingKey] ERROR: Could not create access control")
      throw KeyError.unavailable
    }

    do {
      print("[SecureEnclaveMessagingKey] Creating Secure Enclave P-256 key")
      let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: accessControl)

      print("[SecureEnclaveMessagingKey] Secure Enclave key created")
      print("[SecureEnclaveMessagingKey] Saving key handle to Keychain")
      try save(dataRepresentation: privateKey.dataRepresentation)

      print("[SecureEnclaveMessagingKey] Key handle saved successfully")
      return privateKey

    } catch {
      print("[SecureEnclaveMessagingKey] ERROR while creating/saving key: \(error)")
      throw KeyError.unavailable
    }
  }

  /// Public key to register with backend.
  /// iOS gives us the public key as 64 bytes: X || Y.
  /// Some server-side crypto expects X9.63 format: 0x04 || X || Y.
  /// For registration/JWK we support both.
  public static func publicKeyForKeyBinding() throws -> Data {
    print("[SecureEnclaveMessagingKey] publicKeyForKeyBinding started")

    let rawPublicKey = try getOrCreatePrivateKey().publicKey.rawRepresentation

    print("[SecureEnclaveMessagingKey] raw public key length = \(rawPublicKey.count)")

    if rawPublicKey.count == 64 {
      var x963 = Data([0x04])
      x963.append(rawPublicKey)
      print("[SecureEnclaveMessagingKey] Converted 64-byte raw key to 65-byte X9.63 key")
      return x963
    }

    if rawPublicKey.count == 65 {
      print("[SecureEnclaveMessagingKey] Public key already appears to be X9.63")
      return rawPublicKey
    }

    print("[SecureEnclaveMessagingKey] ERROR: Unexpected public key length = \(rawPublicKey.count)")
    throw KeyError.unavailable
  }

  public struct JWK: Encodable {
    public let crv = "P-256"
    public let kty = "EC"
    public let x: String
    public let y: String
  }

  /// Public key as JWK for backend registration.
  public static func publicKeyJWK() throws -> JWK {
    print("[SecureEnclaveMessagingKey] publicKeyJWK started")

    let point = try publicKeyForKeyBinding()
    let coordinates = try extractP256Coordinates(from: point)

    let jwk = JWK(
      x: coordinates.x.base64URLEncodedString(),
      y: coordinates.y.base64URLEncodedString()
    )

    print("[SecureEnclaveMessagingKey] publicKeyJWK success")
    return jwk
  }

  /// RFC 7638 JWK Thumbprint.
  public static func publicKeyThumbprint() throws -> String {
    print("[SecureEnclaveMessagingKey] publicKeyThumbprint started")

    let jwk = try publicKeyJWK()
    let canonical = "{\"crv\":\"\(jwk.crv)\",\"kty\":\"\(jwk.kty)\",\"x\":\"\(jwk.x)\",\"y\":\"\(jwk.y)\"}"
    let digest = SHA256.hash(data: Data(canonical.utf8))
    let thumbprint = Data(digest).base64URLEncodedString()

    print("[SecureEnclaveMessagingKey] publicKeyThumbprint success: \(thumbprint)")
    return thumbprint
  }

  /// Decrypts an E2EE message locally on device.
  public static func decrypt(
    ciphertextWithTag: Data,
    iv: Data,
    hkdfSalt: Data,
    senderEphemeralPublicKey: Data
  ) throws -> String {
    print("[SecureEnclaveMessagingKey] decrypt started")

    let privateKey = try getOrCreatePrivateKey()
    let ephemeralPublicKey = try makeP256KeyAgreementPublicKey(from: senderEphemeralPublicKey)

    let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
    let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: hkdfSalt,
      sharedInfo: Data("inbox-e2ee-v1".utf8),
      outputByteCount: 32
    )

    let tag = ciphertextWithTag.suffix(16)
    let ciphertext = ciphertextWithTag.dropLast(16)
    let nonce = try AES.GCM.Nonce(data: iv)
    let sealedBox = try AES.GCM.SealedBox(
      nonce: nonce,
      ciphertext: ciphertext,
      tag: tag
    )

    guard let plaintext = String(
      data: try AES.GCM.open(sealedBox, using: symmetricKey),
      encoding: .utf8
    ) else {
      print("[SecureEnclaveMessagingKey] ERROR: Decryption failed")
      throw KeyError.decryptionFailed
    }

    print("[SecureEnclaveMessagingKey] decrypt success")
    return plaintext
  }

  // MARK: - Helpers

  private static func extractP256Coordinates(from point: Data) throws -> (x: Data, y: Data) {
    if point.count == 65 && point.first == 0x04 {
      let x = point.subdata(in: 1..<33)
      let y = point.subdata(in: 33..<65)
      print("[SecureEnclaveMessagingKey] Extracted coordinates from 65-byte X9.63 key")
      return (x, y)
    }

    if point.count == 64 {
      let x = point.subdata(in: 0..<32)
      let y = point.subdata(in: 32..<64)
      print("[SecureEnclaveMessagingKey] Extracted coordinates from 64-byte raw key")
      return (x, y)
    }

    print("[SecureEnclaveMessagingKey] ERROR: Could not extract coordinates. Length = \(point.count)")
    throw KeyError.unavailable
  }

  private static func makeP256KeyAgreementPublicKey(from data: Data) throws -> P256.KeyAgreement.PublicKey {
    if data.count == 65 && data.first == 0x04 {
      let raw = data.subdata(in: 1..<65)
      print("[SecureEnclaveMessagingKey] Converted 65-byte X9.63 public key to 64-byte raw key for CryptoKit")
      return try P256.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    print("[SecureEnclaveMessagingKey] Using public key directly. Length = \(data.count)")
    return try P256.KeyAgreement.PublicKey(rawRepresentation: data)
  }

  // MARK: - Keychain persistence

  private static func save(dataRepresentation: Data) throws {
    print("[SecureEnclaveMessagingKey] save started. Data length = \(dataRepresentation.count)")

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
      print("[SecureEnclaveMessagingKey] ERROR: SecItemAdd failed. Status = \(status)")
      throw KeyError.unavailable
    }

    print("[SecureEnclaveMessagingKey] save success")
  }

  private static func loadPrivateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
    print("[SecureEnclaveMessagingKey] loadPrivateKey started")

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
      print("[SecureEnclaveMessagingKey] No key found in Keychain")
      return nil
    }

    guard status == errSecSuccess, let data = result as? Data else {
      print("[SecureEnclaveMessagingKey] Keychain lookup failed. Status = \(status)")
      return nil
    }

    do {
      let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
      print("[SecureEnclaveMessagingKey] loadPrivateKey success")
      return privateKey
    } catch {
      print("[SecureEnclaveMessagingKey] ERROR: Could not recreate Secure Enclave key: \(error)")
      return nil
    }
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
