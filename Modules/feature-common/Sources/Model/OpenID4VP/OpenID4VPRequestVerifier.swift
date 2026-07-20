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
import Security
import CryptoKit

/// Verifies an OpenID4VP Request Object using `client_id_scheme: x509_san_dns`.
///
/// DEV NOTE:
/// The local prototype can run through a Cloudflare tunnel while the signed
/// request object still contains local/test certificate data. In that case,
/// SecTrust/SAN validation may fail even though the fetched JWT is signed by
/// the certificate in its own x5c header. For local demo work only, this file
/// allows bypassing the SecTrust failure while still verifying the JWS
/// signature against the leaf certificate's public key.
///
/// Do not ship `allowDevTrustBypass = true` in production.
public enum OpenID4VPRequestVerifier {

  private static let allowDevTrustBypass = true

  public enum VerificationError: Error {
    case malformedJWT
    case missingCertificateChain
    case untrustedChain(OSStatus)
    case sanDoesNotMatchClientId(san: String?, clientId: String)
    case unsupportedScheme(String?)
    case invalidSignature
    case expired
  }

  public struct VerifiedRequest {
    public let clientId: String
    public let nonce: String
    public let state: String
    public let responseUri: URL
    public let presentationDefinition: [String: Any]
  }

  public static func verify(requestObjectJWT: String) throws -> VerifiedRequest {
    print("[OpenID4VPRequestVerifier] verify started")

    let parts = requestObjectJWT.split(separator: ".")
    guard parts.count == 3,
          let headerData = base64URLDecode(String(parts[0])),
          let payloadData = base64URLDecode(String(parts[1])),
          let signature = base64URLDecode(String(parts[2])),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else {
      print("[OpenID4VPRequestVerifier] ERROR: malformed JWT")
      throw VerificationError.malformedJWT
    }

    guard let clientIdScheme = payload["client_id_scheme"] as? String,
          clientIdScheme == "x509_san_dns"
    else {
      print("[OpenID4VPRequestVerifier] ERROR: unsupported client_id_scheme \(String(describing: payload["client_id_scheme"]))")
      throw VerificationError.unsupportedScheme(payload["client_id_scheme"] as? String)
    }

    guard let clientId = payload["client_id"] as? String else {
      print("[OpenID4VPRequestVerifier] ERROR: missing client_id")
      throw VerificationError.malformedJWT
    }

    print("[OpenID4VPRequestVerifier] client_id: \(clientId)")

    if let exp = payload["exp"] as? TimeInterval {
      print("[OpenID4VPRequestVerifier] exp: \(exp)")
      if Date(timeIntervalSince1970: exp) < Date() {
        print("[OpenID4VPRequestVerifier] ERROR: request object expired")
        throw VerificationError.expired
      }
    }

    // MARK: - 1. Certificate chain from x5c

    guard let x5c = header["x5c"] as? [String],
          let firstCertificate = x5c.first,
          let leafDer = Data(base64Encoded: firstCertificate)
    else {
      print("[OpenID4VPRequestVerifier] ERROR: missing x5c certificate chain")
      throw VerificationError.missingCertificateChain
    }

    print("[OpenID4VPRequestVerifier] x5c certificate count: \(x5c.count)")
    print("[OpenID4VPRequestVerifier] pinned root count: \(TrustAnchorRegistry.pinnedRootCertificates.count)")

    let intermediateDers = x5c.dropFirst().compactMap { Data(base64Encoded: $0) }

    guard let leafCertificate = SecCertificateCreateWithData(nil, leafDer as CFData) else {
      print("[OpenID4VPRequestVerifier] ERROR: could not create leaf certificate")
      throw VerificationError.missingCertificateChain
    }

    let intermediateCertificates = intermediateDers.compactMap {
      SecCertificateCreateWithData(nil, $0 as CFData)
    }

    // MARK: - 2. Trust chain + SAN/hostname validation

    var trust: SecTrust?
    let policy = SecPolicyCreateSSL(true, clientId as CFString)

    let certificates = [leafCertificate] + intermediateCertificates
    let createTrustStatus = SecTrustCreateWithCertificates(
      certificates as CFArray,
      policy,
      &trust
    )

    guard createTrustStatus == errSecSuccess, let trust else {
      print("[OpenID4VPRequestVerifier] ERROR: SecTrustCreateWithCertificates failed: \(createTrustStatus)")
      throw VerificationError.missingCertificateChain
    }

    SecTrustSetAnchorCertificates(
      trust,
      TrustAnchorRegistry.pinnedRootCertificates as CFArray
    )

    SecTrustSetAnchorCertificatesOnly(trust, true)

    var trustError: CFError?
    let trustOK = SecTrustEvaluateWithError(trust, &trustError)

    if trustOK {
      print("[OpenID4VPRequestVerifier] SecTrust evaluation OK")
    } else {
      let code = OSStatus(trustError.map { CFErrorGetCode($0) } ?? -1)
      let message = trustError.map { CFErrorCopyDescription($0) as String? } ?? nil

      print("[OpenID4VPRequestVerifier] SecTrust evaluation FAILED")
      print("[OpenID4VPRequestVerifier] Trust error code: \(code)")
      print("[OpenID4VPRequestVerifier] Trust error message: \(message ?? "nil")")

      if allowDevTrustBypass {
        print("[OpenID4VPRequestVerifier] DEV BYPASS ENABLED: continuing despite untrusted chain")
      } else {
        throw VerificationError.untrustedChain(code)
      }
    }

    // MARK: - 3. JWT signature verification with leaf certificate public key

    guard let leafPublicKey = SecCertificateCopyKey(leafCertificate) else {
      print("[OpenID4VPRequestVerifier] ERROR: could not copy public key from leaf certificate")
      throw VerificationError.invalidSignature
    }

    var keyError: Unmanaged<CFError>?
    guard let publicKeyData = SecKeyCopyExternalRepresentation(leafPublicKey, &keyError) as Data? else {
      print("[OpenID4VPRequestVerifier] ERROR: could not export public key from certificate")
      throw VerificationError.invalidSignature
    }

    print("[OpenID4VPRequestVerifier] leaf public key length: \(publicKeyData.count)")
    print("[OpenID4VPRequestVerifier] signature length: \(signature.count)")

    let cryptoKitPublicKey: P256.Signing.PublicKey

    do {
      if publicKeyData.count == 65 && publicKeyData.first == 0x04 {
        cryptoKitPublicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        print("[OpenID4VPRequestVerifier] using x963 public key representation")
      } else if publicKeyData.count == 64 {
        cryptoKitPublicKey = try P256.Signing.PublicKey(rawRepresentation: publicKeyData)
        print("[OpenID4VPRequestVerifier] using raw public key representation")
      } else {
        print("[OpenID4VPRequestVerifier] ERROR: unexpected public key length \(publicKeyData.count)")
        throw VerificationError.invalidSignature
      }
    } catch {
      print("[OpenID4VPRequestVerifier] ERROR: could not create CryptoKit public key: \(error)")
      throw VerificationError.invalidSignature
    }

    let ecdsaSignature: P256.Signing.ECDSASignature

    do {
      ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
    } catch {
      print("[OpenID4VPRequestVerifier] ERROR: invalid ECDSA signature format: \(error)")
      throw VerificationError.invalidSignature
    }

    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)

    guard cryptoKitPublicKey.isValidSignature(ecdsaSignature, for: signingInput) else {
      print("[OpenID4VPRequestVerifier] ERROR: JWT signature verification failed")
      throw VerificationError.invalidSignature
    }

    print("[OpenID4VPRequestVerifier] JWT signature verification OK")

    // MARK: - 4. Required OpenID4VP request fields

    guard
      let nonce = payload["nonce"] as? String,
      let state = payload["state"] as? String,
      let responseUriString = payload["response_uri"] as? String,
      let responseUri = URL(string: responseUriString),
      let presentationDefinition = payload["presentation_definition"] as? [String: Any]
    else {
      print("[OpenID4VPRequestVerifier] ERROR: missing required request fields")
      throw VerificationError.malformedJWT
    }

    print("[OpenID4VPRequestVerifier] request object verified")
    print("[OpenID4VPRequestVerifier] nonce: \(nonce)")
    print("[OpenID4VPRequestVerifier] state: \(state)")
    print("[OpenID4VPRequestVerifier] response_uri: \(responseUri.absoluteString)")

    return VerifiedRequest(
      clientId: clientId,
      nonce: nonce,
      state: state,
      responseUri: responseUri,
      presentationDefinition: presentationDefinition
    )
  }

  private static func base64URLDecode(_ value: String) -> Data? {
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    while base64.count % 4 != 0 {
      base64.append("=")
    }

    return Data(base64Encoded: base64)
  }
}
