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

/// "Request by Reference": the app never receives the OpenID4VP request
/// payload directly in the link. It receives a `request_uri` — a Universal
/// Link (iOS) / App Link (Android) — and must fetch the actual signed
/// Request Object itself over HTTPS before it can be verified.
///
/// Why this indirection matters: a Universal Link's OS-level routing (does
/// this look like our domain?) is not a security boundary — it just decides
/// which app opens. The actual trust decision happens AFTER this fetch,
/// in `OpenID4VPRequestVerifier`, which checks the fetched JWT's signature
/// and certificate chain. Fetching over HTTPS also means the request
/// content itself isn't size-limited or malformed by whatever generated the
/// Universal Link (e.g. a QR code, an NFC tag, a notification payload).
public enum RequestByReferenceFetcher {

  public enum FetchError: Error {
    case notARequestByReferenceLink
    case unexpectedContentType(String?)
    case networkError(any Error)
  }

  /// Call this from the app's Universal Link handler
  /// (`Application.swift`'s `.onOpenURL`, or a dedicated
  /// `NSUserActivity`-based handler registered for the associated domain).
  /// `link` looks like `https://inbox-backend.example/keybinding/request-object/{state}`.
  public static func fetchRequestObject(from link: URL) async throws -> String {
    // Real Universal Links are always https. `http` is allowed here only so
    // this prototype can be exercised against a local dev server without a
    // real TLS certificate — never allow this in production.
    guard link.scheme == "https" || link.scheme == "http" else { throw FetchError.notARequestByReferenceLink }

    var request = URLRequest(url: link)
    request.setValue("application/oauth-authz-req+jwt", forHTTPHeaderField: "Accept")

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw FetchError.networkError(error)
    }

    let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
    guard contentType?.contains("oauth-authz-req+jwt") == true else {
      throw FetchError.unexpectedContentType(contentType)
    }

    guard let jwt = String(data: data, encoding: .utf8) else {
      throw FetchError.unexpectedContentType(contentType)
    }
    return jwt
  }

  /// End-to-end helper: fetch AND verify in one call, so callers never hold
  /// an unverified Request Object longer than necessary.
  public static func fetchAndVerify(from link: URL) async throws -> OpenID4VPRequestVerifier.VerifiedRequest {
    let jwt = try await fetchRequestObject(from: link)
    return try OpenID4VPRequestVerifier.verify(requestObjectJWT: jwt)
  }
}
