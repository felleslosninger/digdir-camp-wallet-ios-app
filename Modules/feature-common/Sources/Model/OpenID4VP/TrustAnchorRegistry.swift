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

/// The wallet's pinned list of Trust Anchors (root CAs) it accepts for
/// `client_id_scheme: x509_san_dns` verifiers. In a real deployment this
/// would be a list of national/EU-recognized root certificates (e.g.
/// entries from an EU List of Trusted Lists), shipped with the app and
/// updated out-of-band — never fetched from the verifier itself, since
/// that would let anyone claim to be their own trust anchor.
///
/// This prototype pins exactly ONE root: the one generated in
/// `server/trust-chain/` for local testing. Replace with real trust list
/// data before this goes anywhere near production.
public enum TrustAnchorRegistry {

  // DER (base64), generated via:
  //   openssl req -x509 -new -key root-ca-key.pem ... -out root-ca-cert.pem
  // then: openssl x509 -in root-ca-cert.pem -outform DER | base64
  private static let pinnedRootCertificatesBase64: [String] = [
    """
    MIIBfDCCASICCQD7t+J8svKc5TAKBggqhkjOPQQDAjBGMSYwJAYDVQQDDB1EaWdkaXIgQ2FtcCBUcnVzdCBBbmNob3IgUm9vdDEPMA0GA1UECgwGRGlnZGlyMQswCQYDVQQGEwJOTzAeFw0yNjA3MTAwNjMxNDhaFw0zNjA3MDcwNjMxNDhaMEYxJjAkBgNVBAMMHURpZ2RpciBDYW1wIFRydXN0IEFuY2hvciBSb290MQ8wDQYDVQQKDAZEaWdkaXIxCzAJBgNVBAYTAk5PMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAER9K1rWFmO0u+31NioM38zxtcVI4VMAAsoQGLtFtS/08ee0L6IbLbGPIIrOqZvQr0p6VxFebz8Prf2HC43o+bTDAKBggqhkjOPQQDAgNIADBFAiEAmY4du6ncVQkIRNqMujxsrZ6LobpGKiuHYjEGydVE67wCIDsXQD0Hr2/rG6S3ogOP4/ERnCvctTkYiSnHoo2CMeKJ
    """
  ]

  static var pinnedRootCertificates: [SecCertificate] {
    pinnedRootCertificatesBase64.compactMap { base64 in
      guard let der = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")) else { return nil }
      return SecCertificateCreateWithData(nil, der as CFData)
    }
  }
}
