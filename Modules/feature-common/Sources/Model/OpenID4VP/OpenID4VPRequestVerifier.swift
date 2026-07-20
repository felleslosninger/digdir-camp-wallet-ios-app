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
/// The trust question this answers is: "is the party asking for this
/// presentation really who it claims to be (`client_id`)?" — answered
/// WITHOUT any prior registration or shared secret, purely from a
/// certificate chain rooted in something the wallet already trusts
/// (`TrustAnchorRegistry`). Three checks, all of which must pass:
///
///   1. The leaf certificate in the request's `x5c` header chains up to one
///      of our pinned Trust Anchors (`SecTrust`).
///   2. The leaf certificate's Subject Alternative Name (dNSName) equals
///      the request's `client_id` — this is the actual "x509_san_dns"
///      binding; without it, ANY certificate from a trusted CA could claim
///      to be any client_id.
///   3. The Request Object JWT is actually signed by that leaf certificate's
///      private key (proves the sender holds it, not just that it exists).
public enum OpenID4VPRequestVerifier {

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
    let parts = requestObjectJWT.split(separator: ".")
    guard parts.count == 3,
          let headerData = base64URLDecode(String(parts[0])),
          let payloadData = base64URLDecode(String(parts[1])),
          let signature = base64URLDecode(String(parts[2])),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else {
      throw VerificationError.malformedJWT
    }

    guard let clientIdScheme = payload["client_id_scheme"] as? String, clientIdScheme == "x509_san_dns" else {
      throw VerificationError.unsupportedScheme(payload["client_id_scheme"] as? String)
    }
    guard let clientId = payload["client_id"] as? String else { throw VerificationError.malformedJWT }

    if let exp = payload["exp"] as? TimeInterval, Date(timeIntervalSince1970: exp) < Date() {
      throw VerificationError.expired
    }

    // --- 1. Chain validation against our pinned Trust Anchors ---
    guard let x5c = header["x5c"] as? [String], let leafDer = Data(base64Encoded: x5c[0]) else {
      throw VerificationError.missingCertificateChain
    }
    let intermediateDers = x5c.dropFirst().compactMap { Data(base64Encoded: $0) }
    guard let leafCertificate = SecCertificateCreateWithData(nil, leafDer as CFData) else {
      throw VerificationError.missingCertificateChain
    }
    let intermediateCertificates = intermediateDers.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }

    // `SecCertificateCopyValues` (manual SAN extraction) isn't available on
    // iOS, only macOS. Instead we fold checks 1 and 2 into ONE evaluation:
    // an SSL policy built with `clientId` as the hostname makes SecTrust
    // itself reject the chain unless the leaf's SAN dNSName equals it —
    // exactly the x509_san_dns semantics, using a supported iOS API.
    var trust: SecTrust?
    let policy = SecPolicyCreateSSL(true, clientId as CFString)
    SecTrustCreateWithCertificates([leafCertificate] + intermediateCertificates as CFArray, policy, &trust)
    guard let trust else { throw VerificationError.missingCertificateChain }

    SecTrustSetAnchorCertificates(trust, TrustAnchorRegistry.pinnedRootCertificates as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true) // ONLY our pinned anchors — ignore the system trust store entirely

    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError) else {
      // This single failure covers BOTH "doesn't chain to our trust anchor"
      // AND "SAN doesn't match client_id" — SecPolicyCreateSSL's hostname
      // check is enforced as part of the same evaluation.
      throw VerificationError.untrustedChain(OSStatus(trustError.map { CFErrorGetCode($0) } ?? -1))
    }

    // --- 3. JWT signature verification with the leaf certificate's public key ---
    guard let leafPublicKey = SecCertificateCopyKey(leafCertificate) else {
      throw VerificationError.invalidSignature
    }
    var keyError: Unmanaged<CFError>?
    guard let publicKeyData = SecKeyCopyExternalRepresentation(leafPublicKey, &keyError) as Data? else {
      throw VerificationError.invalidSignature
    }
    let cryptoKitPublicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)

    // JWS ES256 signatures are raw r||s (64 bytes) — exactly what
    // CryptoKit's ECDSASignature(rawRepresentation:) expects, no DER
    // conversion needed on this side.
    let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    guard cryptoKitPublicKey.isValidSignature(ecdsaSignature, for: signingInput) else {
      throw VerificationError.invalidSignature
    }

    guard
      let nonce = payload["nonce"] as? String,
      let state = payload["state"] as? String,
      let responseUriString = payload["response_uri"] as? String,
      let responseUri = URL(string: responseUriString),
      let presentationDefinition = payload["presentation_definition"] as? [String: Any]
    else {
      throw VerificationError.malformedJWT
    }

    return VerifiedRequest(
      clientId: clientId,
      nonce: nonce,
      state: state,
      responseUri: responseUri,
      presentationDefinition: presentationDefinition
    )
  }

  private static func base64URLDecode(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64.append("=") }
    return Data(base64Encoded: base64)
  }
}
