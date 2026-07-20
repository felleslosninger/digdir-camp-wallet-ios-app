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
/// key, committed to via its RFC 7638 thumbprint before any presentation
/// happens. Trust that "this public key belongs to this PID" comes from
/// the wallet's own OpenID4VP presentation of the PID credential.
public enum InboxActivationBackend {

  // Cloudflare tunnel for local development.
  // Keep the cloudflared Terminal window open while testing.
  private static let baseURL = URL(string: "https://analyzed-genetics-adam-pencil.trycloudflare.com")!

  public enum ActivationError: Error {
    case invalidServerResponse
    case keyBindingFailed
    case registrationFailed
  }

  /// Stable per-install identifier sent alongside the push token.
  public static var deviceId: String {
    if let existing = UserDefaults.standard.string(forKey: "inbox_activation_device_id") {
      return existing
    }

    let generated = UUID().uuidString
    UserDefaults.standard.set(generated, forKey: "inbox_activation_device_id")
    return generated
  }

  @MainActor
  public static func activate(pushToken: String) async throws {
    print("[InboxActivationBackend] Starting activation against \(baseURL.absoluteString)")

    let thumbprint = try SecureEnclaveMessagingKey.publicKeyThumbprint()
    print("[InboxActivationBackend] Created Secure Enclave key thumbprint")

    let start = try await startKeyBinding(
      keyThumbprint: thumbprint,
      pushToken: pushToken,
      deviceId: deviceId
    )

    print("[InboxActivationBackend] /keybinding/start OK")

    let rewrittenRequestUri = rewriteLocalhostRequestUri(start.requestUri)

    print("[InboxActivationBackend] request_uri original: \(start.requestUri)")
    print("[InboxActivationBackend] request_uri rewritten: \(rewrittenRequestUri)")

    guard let requestUri = URL(string: rewrittenRequestUri) else {
      throw ActivationError.invalidServerResponse
    }

    let verifiedRequest = try await RequestByReferenceFetcher.fetchAndVerify(from: requestUri)
    print("[InboxActivationBackend] Request object fetched and verified")

    // MOCK: real flow should present PID through wallet/OpenID4VP UI.
    let mockSdHash = "mock-sd-hash-of-disclosed-pid-claims"

    let keyBindingJWT = try HolderBindingKey.buildKeyBindingJWT(
      audience: verifiedRequest.clientId,
      nonce: verifiedRequest.nonce,
      sdHash: mockSdHash
    )

    let sessionToken = try await completeKeyBinding(
      state: verifiedRequest.state,
      mockPid: "99887766554",
      keyBindingJWT: keyBindingJWT
    )

    print("[InboxActivationBackend] /keybinding/callback OK")

    let popJWT = try HolderBindingKey.buildProofOfPossessionJWT(
      sessionToken: sessionToken
    )

    let publicKeyJWK = try SecureEnclaveMessagingKey.publicKeyJWK()

    let registrationId = try await registerKeyBinding(
      sessionToken: sessionToken,
      pushToken: pushToken,
      publicKeyJWK: publicKeyJWK,
      popJWT: popJWT
    )

    print("[InboxActivationBackend] /keybinding/register OK")
    print("[InboxActivationBackend] registration_id: \(registrationId)")

    InboxActivationKeychain.markActivated(registrationId: registrationId)
  }

  public static func refreshPushToken(_ pushToken: String) async {
    guard isActivated else { return }

    // Prototype note:
    // A real deployment would add a dedicated refresh endpoint accepting a
    // signature over a fresh challenge instead of repeating activation.
  }

  public static var isActivated: Bool {
    InboxActivationKeychain.isActivated
  }

  /// The server may return a request URI pointing to localhost because it
  /// runs locally on the Mac. On a physical iPhone, localhost means the
  /// iPhone itself. During Cloudflare testing we rewrite that URI to the
  /// public tunnel base URL.
  private static func rewriteLocalhostRequestUri(_ requestUri: String) -> String {
    guard
      let originalURL = URL(string: requestUri),
      let host = originalURL.host,
      host == "localhost" || host == "127.0.0.1"
    else {
      return requestUri
    }

    guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
      return requestUri
    }

    components.scheme = baseURL.scheme
    components.host = baseURL.host
    components.port = baseURL.port

    return components.url?.absoluteString ?? requestUri
  }

  // MARK: - Private requests

  private static func startKeyBinding(
    keyThumbprint: String,
    pushToken: String,
    deviceId: String
  ) async throws -> StartResponse {
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

    print("[InboxActivationBackend] POST \(url.absoluteString)")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ActivationError.invalidServerResponse
    }

    print("[InboxActivationBackend] /keybinding/start status: \(httpResponse.statusCode)")
    print("[InboxActivationBackend] /keybinding/start response: \(String(data: data, encoding: .utf8) ?? "")")

    guard httpResponse.statusCode == 200 else {
      throw ActivationError.keyBindingFailed
    }

    return try JSONDecoder().decode(StartResponse.self, from: data)
  }

  private static func completeKeyBinding(
    state: String,
    mockPid: String,
    keyBindingJWT: String
  ) async throws -> String {
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

    print("[InboxActivationBackend] POST \(url.absoluteString)")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ActivationError.invalidServerResponse
    }

    print("[InboxActivationBackend] /keybinding/callback status: \(httpResponse.statusCode)")
    print("[InboxActivationBackend] /keybinding/callback response: \(String(data: data, encoding: .utf8) ?? "")")

    guard httpResponse.statusCode == 200 else {
      throw ActivationError.keyBindingFailed
    }

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

    print("[InboxActivationBackend] POST \(url.absoluteString)")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ActivationError.invalidServerResponse
    }

    print("[InboxActivationBackend] /keybinding/register status: \(httpResponse.statusCode)")
    print("[InboxActivationBackend] /keybinding/register response: \(String(data: data, encoding: .utf8) ?? "")")

    guard httpResponse.statusCode == 200 else {
      throw ActivationError.registrationFailed
    }

    return try JSONDecoder().decode(RegisterResponse.self, from: data).registrationId
  }

  // MARK: - Response/request models

  private struct StartResponse: Decodable {
    let requestUri: String
    let state: String

    enum CodingKeys: String, CodingKey {
      case requestUri
      case request_uri
      case state
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      if let camelCaseValue = try container.decodeIfPresent(String.self, forKey: .requestUri) {
        requestUri = camelCaseValue
      } else {
        requestUri = try container.decode(String.self, forKey: .request_uri)
      }

      state = try container.decode(String.self, forKey: .state)
    }
  }

  private struct CallbackResponse: Decodable {
    let sessionToken: String

    enum CodingKeys: String, CodingKey {
      case sessionToken
      case session_token
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      if let camelCaseValue = try container.decodeIfPresent(String.self, forKey: .sessionToken) {
        sessionToken = camelCaseValue
      } else {
        sessionToken = try container.decode(String.self, forKey: .session_token)
      }
    }
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

    enum CodingKeys: String, CodingKey {
      case registrationId
      case registration_id
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      if let camelCaseValue = try container.decodeIfPresent(String.self, forKey: .registrationId) {
        registrationId = camelCaseValue
      } else {
        registrationId = try container.decode(String.self, forKey: .registration_id)
      }
    }
  }
}
