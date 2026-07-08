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
    guard let pushToken = UserDefaults.standard.string(forKey: "apns_device_token") else {
      setState { $0.copy(activationError: "Ingen push-token tilgjengelig ennå. Prøv igjen om litt.") }
      return
    }
    setState { $0.copy(isActivating: true, activationError: nil) }
    Task {
      do {
        try await InboxActivationBackend.activate(pushToken: pushToken)
        setState { $0.copy(isActivated: true, isActivating: false, activationError: nil) }
      } catch {
        setState { $0.copy(isActivating: false, activationError: "Aktivering feilet: \(error.localizedDescription)") }
      }
    }
  }

  func onAppear() {
    load()
    Task { await fetchFromBackend() }
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
    setState { $0.copy(selected: notification) }
  }

  func dismissSelected() {
    setState { $0.copy(selected: nil) }
  }

  func markAsRead(id: String) {
    guard var notifications = viewState.notifications as [ActiveIssuerNotification]?,
          let index = notifications.firstIndex(where: { $0.id == id })
    else { return }
    notifications[index].isRead = true
    setState { $0.copy(notifications: notifications) }
    save(notifications)
  }

  func delete(id: String) {
    let notifications = viewState.notifications.filter { $0.id != id }
    setState { $0.copy(notifications: notifications, selected: nil) }
    save(notifications)
  }

  private func onMyWallet() {
    router.push(
      with: .featureDashboardModule(
        .sideMenu
      )
    )
  }

  private func fetchFromBackend() async {
    let backendBase = "http://10.170.205.1:3000"
    let lastFetchKey = "issuer_notifications_last_fetch"
    var urlString = "\(backendBase)/api/messages"
    if let lastFetch = UserDefaults.standard.string(forKey: lastFetchKey) {
      urlString += "?since=\(lastFetch)"
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let url = URL(string: urlString),
          let (data, _) = try? await URLSession.shared.data(from: url),
          let raw = try? decoder.decode([BackendMessage].self, from: data),
          !raw.isEmpty
    else { return }

    let new = raw.map { ActiveIssuerNotification(from: $0) }
    var existing: [ActiveIssuerNotification] = []
    if let stored = UserDefaults.standard.data(forKey: storageKey),
       let decoded = try? JSONDecoder().decode([ActiveIssuerNotification].self, from: stored) {
      existing = decoded
    }
    let merged = (existing + new).uniqued(by: \.id)
    save(merged)
    UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: lastFetchKey)
    load()
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode([ActiveIssuerNotification].self, from: data)
    else { return }

    let sorted = decoded.sorted { $0.receivedAt > $1.receivedAt }
    setState { $0.copy(notifications: sorted) }
  }

  private func save(_ notifications: [ActiveIssuerNotification]) {
    guard let data = try? JSONEncoder().encode(notifications) else { return }
    UserDefaults.standard.set(data, forKey: storageKey)
  }
}

private struct BackendMessage: Decodable {
  let id: Int
  let issuerName: String
  let title: String
  let body: String
  let actionUrl: String?
  let createdAt: String
}

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

private extension Array {
  func uniqued<T: Hashable>(by keyPath: KeyPath<Element, T>) -> [Element] {
    var seen = Set<T>()
    return filter { seen.insert($0[keyPath: keyPath]).inserted }
  }
}
