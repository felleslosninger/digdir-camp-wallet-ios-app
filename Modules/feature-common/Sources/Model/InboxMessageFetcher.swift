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

/// Fetches and decrypts messages from the E2EE inbox relay. Mirrors
/// `InboxActivationBackend`'s pattern: authenticate with a fresh signature
/// (never a reusable bearer token), then decrypt entirely on-device.
///
/// Two SEPARATE Secure Enclave keys are reused here, each for what it was
/// created for:
/// - `HolderBindingKey` proves "this is the same device that registered" —
///   signs a one-time challenge, same as the PoP-JWT step during activation.
/// - `SecureEnclaveMessagingKey` decrypts the ECIES ciphertext — same ECDH
///   key whose public half was registered and used by senders to encrypt.
public enum InboxMessageFetcher {

  // Replace with your Mac's local IP when testing on a physical device.
  // Port 3001, NOT 3000 — the separate `digdir-wallet-messaging-backend`
  // prototype (used by MessagingBackend.swift / InboxTabViewModel.swift)
  // already runs on 3000. See server/.env.example.
  private static let baseURL = URL(string: "http://10.170.205.1:3001")!

  public enum FetchError: Error {
    case notActivated
    case invalidServerResponse
    case challengeFailed
    case fetchFailed
  }

  public struct DecryptedMessage: Identifiable {
    public let id: String
    public let senderId: String
    public let body: String
    public let createdAt: String
  }

  /// Fetches all pending messages for the currently-activated registration,
  /// decrypting each one locally. Messages that fail to decrypt (e.g. a
  /// corrupted or tampered entry) are dropped rather than crashing the
  /// whole fetch — one bad message shouldn't hide the rest of the inbox.
  public static func fetchMessages() async throws -> [DecryptedMessage] {
    guard let registrationId = InboxActivationKeychain.registrationId else {
      throw FetchError.notActivated
    }

    let nonce = try await requestChallenge(registrationId: registrationId)
    let signature = try HolderBindingKey.sign(nonce: nonce)
    let encryptedMessages = try await fetchEncryptedMessages(
      registrationId: registrationId,
      nonce: nonce,
      signature: signature
    )

    return encryptedMessages.compactMap { message in
      guard
        let ciphertext = Data(base64URLEncoded: message.ciphertext),
        let iv = Data(base64URLEncoded: message.iv),
        let ephemeralPublicKey = Data(base64URLEncoded: message.senderEphemeralPublicKey),
        let salt = Data(base64URLEncoded: message.hkdfSalt),
        let contentHash = Data(base64URLEncoded: message.contentHash),
        let plaintext = try? SecureEnclaveMessagingKey.decrypt(
          ciphertextWithTag: ciphertext,
          iv: iv,
          hkdfSalt: salt,
          senderEphemeralPublicKey: ephemeralPublicKey
        )
      else { return nil }

      // Independent proof-of-content check: AES-GCM's own auth tag already
      // guarantees the ciphertext wasn't tampered with in transit, but this
      // additionally confirms the hash the server recorded (and could be
      // asked to produce as evidence later) matches what we just decrypted
      // — not some other content substituted at record time.
      let actualHash = Data(SHA256.hash(data: Data(plaintext.utf8)))
      guard actualHash == contentHash else { return nil }

      return DecryptedMessage(id: message.id, senderId: message.senderId, body: plaintext, createdAt: message.createdAt)
    }
  }

  // MARK: - Private

  private static func requestChallenge(registrationId: String) async throws -> String {
    guard let url = URL(string: "/messages/challenge/\(registrationId)", relativeTo: baseURL) else {
      throw FetchError.invalidServerResponse
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.challengeFailed }
    return try JSONDecoder().decode(ChallengeResponse.self, from: data).nonce
  }

  private static func fetchEncryptedMessages(
    registrationId: String,
    nonce: String,
    signature: String
  ) async throws -> [EncryptedMessage] {
    guard let url = URL(string: "/messages/fetch", relativeTo: baseURL) else {
      throw FetchError.invalidServerResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode([
      "registration_id": registrationId,
      "nonce": nonce,
      "signature": signature
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.fetchFailed }
    return try JSONDecoder().decode([EncryptedMessage].self, from: data)
  }

  private struct ChallengeResponse: Decodable {
    let nonce: String
  }

  private struct EncryptedMessage: Decodable {
    let id: String
    let senderId: String
    let ciphertext: String
    let iv: String
    let senderEphemeralPublicKey: String
    let hkdfSalt: String
    let contentHash: String
    let createdAt: String
  }
}

private extension Data {
  init?(base64URLEncoded string: String) {
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64.append("=") }
    self.init(base64Encoded: base64)
  }
}
