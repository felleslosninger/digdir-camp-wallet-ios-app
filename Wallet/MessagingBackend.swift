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
import feature_common

enum MessagingBackend {

  // Replace with your Mac's local IP when testing on a physical device.
  // Find it: System Settings → Network → Wi-Fi → Details → IP Address
  private static let baseURL = URL(string: "http://10.170.205.1:3000")!

  private static let storageKey = "issuer_notifications"
  private static let lastFetchKey = "issuer_notifications_last_fetch"

  // MARK: - Device registration

  static func registerDevice(token: String) async {
    guard let url = URL(string: "\(baseURL)/api/devices") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(["deviceToken": token])
    _ = try? await URLSession.shared.data(for: request)
  }

  // MARK: - Message fetch

  static func fetchAndStoreMessages() async {
    var urlString = "\(baseURL)/api/messages"
    if let lastFetch = UserDefaults.standard.string(forKey: lastFetchKey) {
      urlString += "?since=\(lastFetch)"
    }
    print("[Inbox] Fetching messages from \(urlString)")
    guard let url = URL(string: urlString) else {
      print("[Inbox] Invalid URL")
      return
    }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else {
      print("[Inbox] Network request failed")
      return
    }
    print("[Inbox] Response: \(String(data: data, encoding: .utf8) ?? "nil")")
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let raw = try? decoder.decode([BackendMessage].self, from: data), !raw.isEmpty else {
      print("[Inbox] No new messages decoded")
      return
    }

    let new = raw.map { ActiveIssuerNotification(from: $0) }
    var existing: [ActiveIssuerNotification] = []
    if let stored = UserDefaults.standard.data(forKey: storageKey),
       let decoded = try? JSONDecoder().decode([ActiveIssuerNotification].self, from: stored) {
      existing = decoded
    }

    let merged = (existing + new).uniqued(by: \.id)
    if let encoded = try? JSONEncoder().encode(merged) {
      UserDefaults.standard.set(encoded, forKey: storageKey)
    }
    UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: lastFetchKey)
  }
}

// MARK: - Backend DTO

private struct BackendMessage: Decodable {
  let id: Int
  let issuerName: String
  let title: String
  let body: String
  let actionUrl: String?
  let createdAt: String
}

// MARK: - Model mapping

private extension ActiveIssuerNotification {
  init(from message: BackendMessage) {
    self.init(
      issuerName: message.issuerName,
      title: message.title,
      body: message.body,
      actionURL: message.actionUrl.flatMap { URL(string: $0) }
    )
  }
}

// MARK: - Helpers

private extension Array {
  func uniqued<T: Hashable>(by keyPath: KeyPath<Element, T>) -> [Element] {
    var seen = Set<T>()
    return filter { seen.insert($0[keyPath: keyPath]).inserted }
  }
}
