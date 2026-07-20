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

@preconcurrency import Foundation
import logic_ui
import feature_common
import Observation

@Copyable
struct InboxTabState: ViewState {
  let notifications: [ActiveIssuerNotification]
  let selected: ActiveIssuerNotification?
  let isActivated: Bool
  let isActivating: Bool
  let activationError: String?
}

@Observable
final class InboxTabViewModel<Router: RouterHost>: ViewModel<Router, InboxTabState> {

  @ObservationIgnored
  private let onUpdateToolbar: (ToolBarContent, LocalizableStringKey) -> Void

  @ObservationIgnored
  private var inboxRefreshObserver: NSObjectProtocol?

  @ObservationIgnored
  private var isFetchingMessages: Bool = false

  @ObservationIgnored
  private var lastFetchStartedAt: Date?

  private let minimumFetchInterval: TimeInterval = 1.0
  private let storageKey = "issuer_notifications"

  init(
    router: Router,
    onUpdateToolbar: @escaping (ToolBarContent, LocalizableStringKey) -> Void
  ) {
    self.onUpdateToolbar = onUpdateToolbar

    super.init(
      router: router,
      initialState: .init(
        notifications: [],
        selected: nil,
        isActivated: InboxActivationBackend.isActivated,
        isActivating: false,
        activationError: nil
      )
    )
  }

  func activate() {
    let pushToken = UserDefaults.standard.string(forKey: "apns_device_token") ?? "demo-push-token"

    print("[InboxTabViewModel] Activation started")

    setState {
      $0.copy(
        isActivating: true,
        activationError: nil
      )
    }

    Task {
      do {
        try await InboxActivationBackend.activate(pushToken: pushToken)

        print("[InboxTabViewModel] Activation succeeded")

        setState {
          $0.copy(
            isActivated: true,
            isActivating: false,
            activationError: nil
          )
        }

        await fetchFromBackend()

      } catch {
        let message = Self.activationErrorMessage(for: error)

        print("[InboxTabViewModel] Activation failed: \(error)")
        print("[InboxTabViewModel] Activation user message: \(message)")

        setState {
          $0.copy(
            isActivated: false,
            isActivating: false,
            activationError: message
          )
        }
      }
    }
  }

  func onAppear() {
    load()
    startListeningForInboxRefresh()

    let activated = InboxActivationBackend.isActivated

    if activated != viewState.isActivated {
      setState {
        $0.copy(isActivated: activated)
      }
    }

    if activated {
      Task {
        await fetchFromBackend()
      }
    }

    onUpdateToolbar(
      .init(
        trailingActions: nil,
        leadingActions: [
          .init(
            image: Theme.shared.image.menuIcon,
            accessibilityLocator: ToolbarLocators.menuButton
          ) {
            self.onMyWallet()
          }
        ]
      ),
      .inbox
    )
  }

  func select(_ notification: ActiveIssuerNotification) {
    setState {
      $0.copy(selected: notification)
    }
  }

  func dismissSelected() {
    setState {
      $0.copy(selected: nil)
    }
  }

  func markAsRead(id: String) {
    var notifications = viewState.notifications

    guard let index = notifications.firstIndex(where: { $0.id == id }) else {
      return
    }

    notifications[index].isRead = true

    setState {
      $0.copy(notifications: notifications)
    }

    save(notifications)
  }

  func delete(id: String) {
    let notifications = viewState.notifications.filter { $0.id != id }

    setState {
      $0.copy(
        notifications: notifications,
        selected: nil
      )
    }

    save(notifications)
  }

  private func onMyWallet() {
    router.push(
      with: .featureDashboardModule(
        .sideMenu
      )
    )
  }

  // MARK: - Push-triggered refresh

  private func startListeningForInboxRefresh() {
    guard inboxRefreshObserver == nil else {
      return
    }

    inboxRefreshObserver = NotificationCenter.default.addObserver(
      forName: .inboxShouldRefresh,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else {
        return
      }

      print("[InboxTabViewModel] Received inboxShouldRefresh notification")

      Task {
        await self.fetchFromBackend()
      }
    }

    print("[InboxTabViewModel] Started listening for push-triggered inbox refresh")
  }

  // MARK: - Backend fetch

  private func fetchFromBackend() async {
    let now = Date()

    if isFetchingMessages {
      print("[InboxTabViewModel] Fetch already running. Skipping duplicate refresh.")
      return
    }

    if let lastFetchStartedAt,
       now.timeIntervalSince(lastFetchStartedAt) < minimumFetchInterval {
      print("[InboxTabViewModel] Fetch triggered too soon after previous fetch. Skipping duplicate refresh.")
      return
    }

    guard InboxActivationBackend.isActivated else {
      print("[InboxTabViewModel] Inbox is not activated. Skipping fetch.")
      return
    }

    isFetchingMessages = true
    lastFetchStartedAt = now

    defer {
      isFetchingMessages = false
    }

    print("[InboxTabViewModel] fetchFromBackend started")

    do {
      let decryptedMessages = try await InboxMessageFetcher.fetchMessages()

      print("[InboxTabViewModel] Backend returned \(decryptedMessages.count) decrypted messages")

      guard !decryptedMessages.isEmpty else {
        print("[InboxTabViewModel] No backend messages yet. Keeping current UI.")
        return
      }

      let notifications = decryptedMessages.map {
        ActiveIssuerNotification(from: $0)
      }

      save(notifications)

      setState {
        $0.copy(notifications: notifications)
      }

      print("[InboxTabViewModel] Backend messages saved and pushed to UI")

    } catch {
      print("[InboxTabViewModel] fetchFromBackend failed: \(error)")
    }
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode([ActiveIssuerNotification].self, from: data)
    else {
      print("[InboxTabViewModel] No stored notifications found")
      return
    }

    let sorted = decoded.sorted {
      $0.receivedAt > $1.receivedAt
    }

    print("[InboxTabViewModel] Loaded \(sorted.count) stored notifications")

    setState {
      $0.copy(notifications: sorted)
    }
  }

  private func save(_ notifications: [ActiveIssuerNotification]) {
    guard let data = try? JSONEncoder().encode(notifications) else {
      print("[InboxTabViewModel] Failed to encode notifications")
      return
    }

    UserDefaults.standard.set(data, forKey: storageKey)
    print("[InboxTabViewModel] Saved \(notifications.count) notifications")
  }

  // MARK: - Error messages

  private static func activationErrorMessage(for error: Error) -> String {
    let nsError = error as NSError

    if nsError.domain == NSURLErrorDomain {
      switch nsError.code {
      case NSURLErrorNotConnectedToInternet:
        return "Kunne ikke aktivere innboksen fordi telefonen ikke har internettforbindelse."

      case NSURLErrorCannotFindHost:
        return "Kunne ikke finne innboks-serveren. Sjekk at tunnel-URL-en er riktig og at Cloudflare-tunnelen kjører."

      case NSURLErrorCannotConnectToHost:
        return "Kunne ikke koble til innboks-serveren. Sjekk at backend-serveren kjører."

      case NSURLErrorTimedOut:
        return "Aktiveringen tok for lang tid. Sjekk nettverk, backend-server og tunnel."

      case NSURLErrorSecureConnectionFailed:
        return "Sikker tilkobling til innboks-serveren feilet."

      default:
        return "Aktivering av sikker innboks feilet. Prøv igjen."
      }
    }

    return "Aktivering av sikker innboks feilet. Prøv igjen."
  }
}

// MARK: - Mapping from E2EE backend messages to UI notifications

private extension ActiveIssuerNotification {

  init(from message: InboxMessageFetcher.DecryptedMessage) {
    let senderName = Self.displayName(for: message.senderId)

    self.init(
      issuerName: senderName,
      title: "Ny melding fra \(senderName)",
      body: message.body,
      actionURL: Self.actionURL(for: message.senderId)
    )
  }

  static func displayName(for senderId: String) -> String {
    let normalized = senderId.lowercased()

    if normalized.contains("skatte") {
      return "Skatteetaten"
    }

    if normalized.contains("nav") {
      return "NAV"
    }

    if normalized.contains("lane") || normalized.contains("låne") {
      return "Lånekassen"
    }

    if normalized.contains("vegvesen") {
      return "Statens vegvesen"
    }

    return senderId
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }

  static func actionURL(for senderId: String) -> URL? {
    let normalized = senderId.lowercased()

    if normalized.contains("skatte") {
      return URL(string: "https://www.skatteetaten.no")
    }

    if normalized.contains("nav") {
      return URL(string: "https://www.nav.no")
    }

    if normalized.contains("lane") || normalized.contains("låne") {
      return URL(string: "https://www.lanekassen.no")
    }

    if normalized.contains("vegvesen") {
      return URL(string: "https://www.vegvesen.no")
    }

    return nil
  }
}

// MARK: - Internal inbox refresh notification

extension Notification.Name {
  static let inboxShouldRefresh = Notification.Name("inboxShouldRefresh")
}
