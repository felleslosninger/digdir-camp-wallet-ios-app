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
import feature_common
import Observation

@Copyable
struct HomeTabState: ViewState {
  let username: String?
  let contentHeaderConfig: ContentHeaderConfig
  let phase: ScenePhase
  let pendingBleModalAction: Bool
}

@Observable
final class HomeTabViewModel<Router: RouterHost>: ViewModel<Router, HomeTabState> {

  @ObservationIgnored
  private let interactor: HomeTabInteractor
  @ObservationIgnored
  private let onUpdateToolbar: (ToolBarContent, LocalizableStringKey) -> Void

  var isAuthenticateAlertShowing: Bool = false
  var isAuthenticateModalShowing: Bool = false
  var isSignDocumentAlertShowing: Bool = false
  var isBleModalShowing: Bool = false
  var notifications: [ActiveIssuerNotification] = []

  var oldestUnread: ActiveIssuerNotification? {
    notifications.first(where: { !$0.isRead })
  }

  var unreadCount: Int {
    notifications.filter { !$0.isRead }.count
  }

  @ObservationIgnored
  private var notificationObserver: NSObjectProtocol?

  private let storageKey = "issuer_notifications"
  private let expiryDays: Double = 30

  init(
    router: Router,
    interactor: HomeTabInteractor,
    onUpdateToolbar: @escaping (ToolBarContent, LocalizableStringKey) -> Void
  ) {
    self.interactor = interactor
    self.onUpdateToolbar = onUpdateToolbar
    super.init(
      router: router,
      initialState: .init(
        username: nil,
        contentHeaderConfig: .init(
          appIconAndTextData: AppIconAndTextData(
            appIcon: ThemeManager.shared.image.logoEuDigitalIndentityWallet
          )
        ),
        phase: .active,
        pendingBleModalAction: false
      )
    )
  }

  func onCreate() async {
    loadNotifications()

    notificationObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.IssuerNotificationReceived,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let issuerName = notification.userInfo?["issuerName"] as? String ?? ""
      let title = notification.userInfo?["title"] as? String ?? ""
      let body = notification.userInfo?["body"] as? String ?? ""
      let actionURL = notification.userInfo?["actionURL"] as? URL
      let newNotification = ActiveIssuerNotification(
        issuerName: issuerName,
        title: title,
        body: body,
        actionURL: actionURL
      )
      Task { @MainActor [weak self] in
        self?.notifications.append(newNotification)
        self?.saveNotifications()
      }
    }

    let username = await interactor.fetchUsername()
    setState { $0.copy(username: getUserName(username)) }
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
      .home
    )
  }

  func toggleAuthenticateAlert() {
    isAuthenticateAlertShowing.toggle()
  }

  func toggleAuthenticateModal() {
    isAuthenticateModalShowing.toggle()
  }

  func toggleSignDocumentAlert() {
    isSignDocumentAlertShowing.toggle()
  }

  func openSignDocument() {
    router.push(with: .featureDashboardModule(.signDocument))
  }

  func onShowScanner() {
    router.push(with: .featureCommonModule(.qrScanner(config: ScannerUiConfig(flow: .presentation))))
  }

  func onShare() {
    Task {

      let state = await interactor.getBleAvailability()

      switch state {
      case .available:
        self.router.push(
          with: .featureProximityModule(
            .proximityConnection(
              presentationCoordinator: await self.interactor.getWalletKitController().startProximityPresentation(),
              originator: .featureDashboardModule(.dashboard)
            )
          )
        )
      case .noPermission, .disabled:
        self.toggleBleModal()
      default:
        break
      }
    }
  }

  func toggleBleModal() {
    guard viewState.phase == .active else {
      setState { $0.copy(pendingBleModalAction: true) }
      return
    }
    isBleModalShowing = !isBleModalShowing
  }

  func onBleSettings() {
    toggleBleModal()
    Task { await interactor.openBleSettings() }
  }

  func setPhase(with phase: ScenePhase) {
    setState { $0.copy(phase: phase) }
    if phase == .active && viewState.pendingBleModalAction {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
        self.setState { $0.copy(pendingBleModalAction: false) }
        self.toggleBleModal()
      }
    }
  }

  private func onMyWallet() {
    router.push(
      with: .featureDashboardModule(
        .sideMenu
      )
    )
  }

  func addTestNotification() {
    let new = ActiveIssuerNotification(
      issuerName: "Skatteetaten",
      title: "Skattekortet ditt er klart",
      body: "En arbeidsgiver har bedt om skattekortet ditt. Logg inn på Skatteetaten for å se detaljer.",
      actionURL: nil
    )
    notifications.append(new)
    saveNotifications()
  }

  func markAsRead(id: String) {
    guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
    notifications[index].isRead = true
    saveNotifications()
  }

  func dismiss(id: String) {
    notifications.removeAll { $0.id == id }
    saveNotifications()
  }

  @MainActor
  private func loadNotifications() {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode([ActiveIssuerNotification].self, from: data)
    else { return }

    let cutoff = Date().addingTimeInterval(-expiryDays * 86400)
    notifications = decoded
      .filter { $0.receivedAt > cutoff }
      .sorted { $0.receivedAt < $1.receivedAt }
  }

  @MainActor
  private func saveNotifications() {
    guard let data = try? JSONEncoder().encode(notifications) else { return }
    UserDefaults.standard.set(data, forKey: storageKey)
  }

  private func getUserName(_ username: String) -> String {
    let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedUsername.isEmpty ? "" : ", \(trimmedUsername)"
  }
}
