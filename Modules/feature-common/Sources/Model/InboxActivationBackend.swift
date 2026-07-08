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

/// Talks to the `server/` prototype's key-binding endpoints. The backend
/// never authenticates the user directly — it only ever receives a public
/// key, committed to (via its RFC 7638 thumbprint) BEFORE any presentation
/// happens, and re-proven at the very end via a fresh signature. Trust that
/// "this public key belongs to this PID" comes from the wallet's own
/// OpenID4VP presentation of the PID credential.
public enum InboxActivationBackend {

  // Replace with your Mac's local IP when testing on a physical device.
  // Port 3001, NOT 3000 — the separate `digdir-wallet-messaging-backend`
  // prototype (used by MessagingBackend.swift / InboxTabViewModel.swift)
  // already runs on 3000. See server/.env.example.
  private static let baseURL = URL(string: "http://10.170.205.1:3001")!

  public enum ActivationError: Error {
    case invalidServerResponse
    case keyBindingFailed
    case registrationFailed
  }

  /// Stable per-install identifier sent alongside the push token — lets the
  /// backend tell "same phone, new push token" apart from "different phone".
  public static var deviceId: String {
    if let existing = UserDefaults.standard.string(forKey: "inbox_activation_device_id") {
      return existing
    }
    let generated = UUID().uuidString
    UserDefaults.standard.set(generated, forKey: "inbox_activation_device_id")
    return generated
  }

  /// One-time key binding, in three steps that are each independently
  /// re-verified rather than trusting a single artifact all the way through:
  ///
  /// 1. **Commit** (`/keybinding/start`): compute the messaging key's RFC
  ///    7638 thumbprint and send ONLY that (not the full key) before any
  ///    presentation happens. The backend bakes it into the OpenID4VP
  ///    request's nonce as `"<uuid>.<thumbprint>"` — so it already knows
  ///    which key it expects before it's shown anything.
  /// 2. **Present** (`/keybinding/callback`): fetch + verify the Request
  ///    Object (Request by Reference, x509_san_dns chain check), present the
  ///    PID, and sign a Key Binding JWT over that same nonce. On success the
  ///    backend does NOT register anything yet — it only hands back a
  ///    single-use `session_token`.
  /// 3. **Register** (`/keybinding/register`): send the actual public key
  ///    (as a JWK) plus a FRESH Proof-of-Possession JWT signed over that
  ///    session_token. The backend cross-checks the JWK's thumbprint against
  ///    what was committed in step 1, and verifies the fresh signature,
  ///    before finally persisting the registration.
  ///
  /// Building the actual Verifiable Presentation (the SD-JWT PID disclosure
  /// itself) is MOCKED below — wiring this to the app's real
  /// `WalletKitController`/OpenID4VP presentation flow (already a
  /// dependency of this project) is the remaining real integration work.
  @MainActor
  public static func activate(pushToken: String) async throws {
    let thumbprint = try SecureEnclaveMessagingKey.publicKeyThumbprint()

    let start = try await startKeyBinding(keyThumbprint: thumbprint, pushToken: pushToken, deviceId: deviceId)
    guard let requestUri = URL(string: start.requestUri) else { throw ActivationError.invalidServerResponse }

    // Request by Reference: fetch the signed Request Object, then verify
    // its x509_san_dns chain BEFORE trusting anything inside it. Its nonce
    // already contains the thumbprint we committed above.
    let verifiedRequest = try await RequestByReferenceFetcher.fetchAndVerify(from: requestUri)

    // --- MOCK: real flow presents verifiedRequest.presentationDefinition
    // to the wallet's own OpenID4VP presentation UI, which selects/discloses
    // the PID SD-JWT credential. `sdHash` below stands in for
    // SHA-256(issuer-signed JWT + disclosures), per the SD-JWT VC spec. ---
    let mockSdHash = "mock-sd-hash-of-disclosed-pid-claims"
    // -----------------------------------------------------------------

    let keyBindingJWT = try HolderBindingKey.buildKeyBindingJWT(
      audience: verifiedRequest.clientId,
      nonce: verifiedRequest.nonce,
      sdHash: mockSdHash
    )

    let sessionToken = try await completeKeyBinding(
      state: verifiedRequest.state,
      mockPid: "01020312345",
      keyBindingJWT: keyBindingJWT
    )

    // Fresh proof of possession, decoupled from the presentation: proves
    // we still hold the key right now, not just that we once did.
    let popJWT = try HolderBindingKey.buildProofOfPossessionJWT(sessionToken: sessionToken)
    let publicKeyJWK = try SecureEnclaveMessagingKey.publicKeyJWK()

    let registrationId = try await registerKeyBinding(
      sessionToken: sessionToken,
      pushToken: pushToken,
      publicKeyJWK: publicKeyJWK,
      popJWT: popJWT
    )

    InboxActivationKeychain.markActivated(registrationId: registrationId)
  }

  /// Call whenever the OS hands the app a new push token. If the inbox was
  /// never activated, this is a no-op — activation must be a deliberate,
  /// user-initiated action (the "Aktiver" button), not something that
  /// silently happens on token refresh.
  public static func refreshPushToken(_ pushToken: String) async {
    guard isActivated else { return }
    // A full deployment would add a dedicated refresh endpoint accepting a
    // signature over a fresh challenge (same pattern as the PoP-JWT above)
    // instead of repeating the whole key-binding ceremony. Omitted here for
    // brevity — see README.
  }

  public static var isActivated: Bool {
    InboxActivationKeychain.isActivated
  }

  // MARK: - Private

  private static func startKeyBinding(keyThumbprint: String, pushToken: String, deviceId: String) async throws -> StartResponse {
    guard let url = URL(string: "/keybinding/start", relativeTo: baseURL) else {
      throw ActivationError.invalidServerResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode([
      "key_thumbprint": keyThumbprint,
      "fcm_token": pushToken,
      "device_id": deviceId
    ])

    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(StartResponse.self, from: data)
  }

  private static func completeKeyBinding(state: String, mockPid: String, keyBindingJWT: String) async throws -> String {
    guard let url = URL(string: "/keybinding/callback", relativeTo: baseURL) else {
      throw ActivationError.invalidServerResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode([
      "state": state,
      "mock_pid": mockPid,
      "key_binding_jwt": keyBindingJWT
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ActivationError.keyBindingFailed }
    return try JSONDecoder().decode(CallbackResponse.self, from: data).sessionToken
  }

  private static func registerKeyBinding(
    sessionToken: String,
    pushToken: String,
    publicKeyJWK: SecureEnclaveMessagingKey.JWK,
    popJWT: String
  ) async throws -> String {
    guard let url = URL(string: "/keybinding/register", relativeTo: baseURL) else {
      throw ActivationError.invalidServerResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(RegisterRequest(
      sessionToken: sessionToken,
      fcmToken: pushToken,
      publicKeyJwk: publicKeyJWK,
      popJwt: popJWT
    ))

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ActivationError.registrationFailed }
    return try JSONDecoder().decode(RegisterResponse.self, from: data).registrationId
  }

  private struct StartResponse: Decodable {
    let requestUri: String
    let state: String
  }

  private struct CallbackResponse: Decodable {
    let sessionToken: String
  }

  private struct RegisterRequest: Encodable {
    let sessionToken: String
    let fcmToken: String
    let publicKeyJwk: SecureEnclaveMessagingKey.JWK
    let popJwt: String

    enum CodingKeys: String, CodingKey {
      case sessionToken = "session_token"
      case fcmToken = "fcm_token"
      case publicKeyJwk = "public_key_jwk"
      case popJwt = "pop_jwt"
    }
  }

  private struct RegisterResponse: Decodable {
    let registrationId: String
  }
}
