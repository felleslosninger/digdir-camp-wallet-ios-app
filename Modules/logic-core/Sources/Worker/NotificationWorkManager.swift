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

public protocol NotificationWorkManager: Sendable {
  func start() async
  func stop() async
  func simulateNotification() async
  func printStatusIdentifiers() async
}

// Represents a notification fetched from an issuer's endpoint
public struct IssuerNotification: Sendable {
  public let documentId: String
  public let issuerName: String
  public let title: String
  public let body: String
  public let actionURL: URL?
}

final actor NotificationWorkManagerImpl: NotificationWorkManager {

  private let configLogic: WalletKitConfig
  private let walletKitController: WalletKitController

  private let initialDelay: TimeInterval = 30
  private let pollingIntervalSeconds: TimeInterval = 300
  private var notificationTask: Task<Void, Never>?
  private var isRunning = false

  // Tracks which document IDs we have already notified the user about,
  // so we don't re-notify on every poll while status remains suspended.
  private var notifiedDocumentIds: Set<String> = []

  init(configLogic: WalletKitConfig, walletKitController: WalletKitController) {
    self.configLogic = configLogic
    self.walletKitController = walletKitController
  }

  func start() async {
    guard notificationTask == nil else { return }
    isRunning = true
    notificationTask = Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      try? await Task.sleep(seconds: initialDelay)
      while await self.isRunning {
        try? await self.checkForNotifications()
        try? await Task.sleep(seconds: self.pollingIntervalSeconds)
      }
    }
  }

  func stop() async {
    isRunning = false
    notificationTask?.cancel()
    notificationTask = nil
  }

  func printStatusIdentifiers() async {
    let documents = await walletKitController.fetchIssuedDocuments()
    for doc in documents {
      print("=== DOKUMENT: \(doc.displayName.orEmpty) ===")
      print("    id: \(doc.id)")
      if let si = doc.statusIdentifier {
        print("    statusIdentifier uri: \(si.uriString)")
        print("    statusIdentifier idx: \(si.idx)")
      } else {
        print("    ingen statusIdentifier")
      }
    }
  }

  func simulateNotification() async {
    let documents = await walletKitController.fetchIssuedDocuments()
    guard let first = documents.first else { return }
    let notification = await fetchNotificationContent(for: first)
    await notifyListeners(with: notification)
  }

  private func checkForNotifications() async throws {
    let issuedDocuments = await walletKitController.fetchIssuedDocuments()

    for document in issuedDocuments {
      guard let identifier = document.statusIdentifier else { continue }
      guard !notifiedDocumentIds.contains(document.id) else { continue }

      let status = try await walletKitController.getDocumentStatus(for: identifier)

      guard status == .suspended else {
        // If status returned to valid, allow re-notification next time it becomes suspended
        notifiedDocumentIds.remove(document.id)
        continue
      }

      // Fetch rich notification content from the issuer's endpoint if available.
      // The issuer embeds a "notification_url" claim in the credential pointing
      // to an endpoint they control — this is what makes the channel phishing-resistant:
      // the URL was signed by the issuer at issuance time.
      let notification = await fetchNotificationContent(for: document)
      notifiedDocumentIds.insert(document.id)
      await notifyListeners(with: notification)
    }
  }

  private func fetchNotificationContent(for document: any DocClaimsDecodable) async -> IssuerNotification {
    // TODO: extract "notification_url" from document claims and fetch JSON from it.
    // For now, return a hardcoded placeholder so the UI flow can be tested end-to-end.
    return IssuerNotification(
      documentId: document.id,
      issuerName: document.displayName.orEmpty,
      title: "Skattekortet ditt er klart",
      body: "En arbeidsgiver har bedt om skattekortet ditt. Logg inn på Skatteetaten for å se detaljer.",
      actionURL: nil
    )
  }

  @MainActor
  private func notifyListeners(with notification: IssuerNotification) async {
    NotificationCenter.default.post(
      name: NSNotification.IssuerNotificationReceived,
      object: nil,
      userInfo: [
        "documentId": notification.documentId,
        "issuerName": notification.issuerName,
        "title": notification.title,
        "body": notification.body,
        "actionURL": notification.actionURL as Any
      ]
    )
  }
}

public extension NSNotification {
  static let IssuerNotificationReceived = Notification.Name("IssuerNotificationReceived")
}
