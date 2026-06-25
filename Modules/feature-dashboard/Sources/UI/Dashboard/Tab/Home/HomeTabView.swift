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
import SwiftUI
import logic_ui
import logic_resources

struct HomeTabView<Router: RouterHost>: View {

  @Environment(\.scenePhase) private var scenePhase

  @State private var viewModel: HomeTabViewModel<Router>

  init(with viewModel: HomeTabViewModel<Router>) {
    self._viewModel = State(wrappedValue: viewModel)
  }

  var body: some View {
    HomeTabViewContainer(
      viewState: viewModel.viewState,
      isAuthenticateAlertShowing: $viewModel.isAuthenticateAlertShowing,
      isSignDocumentAlertShowing: $viewModel.isSignDocumentAlertShowing,
      oldestUnread: viewModel.oldestUnread,
      unreadCount: viewModel.unreadCount,
      toggleAuthenticateAlert: { viewModel.toggleAuthenticateAlert() },
      toggleAuthenticateModal: { viewModel.toggleAuthenticateModal() },
      openSignDocument: { viewModel.openSignDocument() },
      toggleSignDocumentAlert: { viewModel.toggleSignDocumentAlert() },
      onMarkRead: { viewModel.markAsRead(id: $0) },
      onDismiss: { viewModel.dismiss(id: $0) },
      onAddTestNotification: { viewModel.addTestNotification() }
    )
    .confirmationDialog(
      .authenticate,
      isPresented: $viewModel.isAuthenticateModalShowing,
      titleVisibility: .visible
    ) {
      Button(.inPerson) {
        viewModel.onShare()
      }
      .accessibilityLocator(HomeTabViewLocators.inPersonButton)

      Button(.online) {
        viewModel.onShowScanner()
      }
      .accessibilityLocator(HomeTabViewLocators.onlineButton)

      if ProcessInfo.processInfo.isiOSAppOnMac {
          Button(.cancelButton, role: .cancel) {}
            .accessibilityLocator(HomeTabViewLocators.cancelButton)
      } else {
          Button(.cancelButton) {}
            .accessibilityLocator(HomeTabViewLocators.cancelButton)
      }
    } message: {
        Text(.authenticateAuthoriseTransactions)
      .dialogCompat(
        .bleDisabledModalTitle,
        isPresented: $viewModel.isBleModalShowing,
        actions: {
          Button(.bleDisabledModalButton) {
            viewModel.onBleSettings()
          }
          if !ProcessInfo.processInfo.isiOSAppOnMac {
              Button(.cancelButton, role: .cancel) {}
          }
        },
        message: {
          Text(.bleDisabledModalCaption)
        }
      )
      .onChange(of: scenePhase) {
        self.viewModel.setPhase(with: scenePhase)
      }
      .task {
        await viewModel.onCreate()
      }
      .background(Theme.shared.color.background)
    }
  }
}

private struct HomeTabViewContainer: View {

  let viewState: HomeTabState
  @Binding var isAuthenticateAlertShowing: Bool
  @Binding var isSignDocumentAlertShowing: Bool
  let oldestUnread: ActiveIssuerNotification?
  let unreadCount: Int
  @State private var isSheetShowing: Bool = false
  let toggleAuthenticateAlert: () -> Void
  let toggleAuthenticateModal: () -> Void
  let openSignDocument: () -> Void
  let toggleSignDocumentAlert: () -> Void
  let onMarkRead: (String) -> Void
  let onDismiss: (String) -> Void
  let onAddTestNotification: () -> Void

  var body: some View {
    content()
  }

  @MainActor
  @ViewBuilder
  private func content() -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SPACING_MEDIUM) {
        ContentHeaderView(
          config: viewState.contentHeaderConfig
        )

        if let username = viewState.username {
          Text(.welcomeBack([username]))
            .font(Theme.shared.font.titleMedium.font)
            .foregroundStyle(Theme.shared.color.primaryLabel)
            .accessibilityLocator(HomeTabViewLocators.userNameText)
        }

        if let notification = oldestUnread {
          Button {
            isSheetShowing = true
          } label: {
            HStack(spacing: SPACING_SMALL) {
              ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                  .foregroundStyle(Theme.shared.color.accent)
                  .font(.system(size: 20))
                Circle()
                  .fill(Theme.shared.color.red)
                  .frame(width: 10, height: 10)
                  .offset(x: 4, y: -4)
              }
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SPACING_SMALL) {
                  Text(notification.issuerName)
                    .typography(Theme.shared.font.labelLarge)
                    .foregroundStyle(Theme.shared.color.primaryLabel)
                  if unreadCount > 1 {
                    Text("+\(unreadCount - 1) til")
                      .typography(Theme.shared.font.bodySmall)
                      .foregroundStyle(Theme.shared.color.secondaryLabel)
                  }
                }
                Text(notification.title)
                  .typography(Theme.shared.font.bodyMedium)
                  .foregroundStyle(Theme.shared.color.secondaryLabel)
                  .lineLimit(1)
              }
              Spacer()
              Image(systemName: "chevron.right")
                .foregroundStyle(Theme.shared.color.secondaryLabel)
                .font(.system(size: 14))
            }
            .padding(SPACING_MEDIUM)
            .background(Theme.shared.color.groupedElevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.shared.color.accent.opacity(0.3), lineWidth: 1)
            )
          }
          .sheet(isPresented: $isSheetShowing) {
            IssuerNotificationDetailView(
              notification: notification,
              onMarkRead: { onMarkRead(notification.id) },
              onDismiss: {
                isSheetShowing = false
                onDismiss(notification.id)
              }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
          }
        }

        Button("Test varsel") {
          onAddTestNotification()
        }

        HomeCardView(
          text: LocalizableStringKey.authenticateAuthoriseTransactions,
          locator: HomeTabViewLocators.authenticateAuthoriseTransactions,
          buttonText: LocalizableStringKey.authenticate,
          illustration: Theme.shared.image.homeIdentity,
          learnMoreText: LocalizableStringKey.learnMore,
          learnMoreAction: {
            toggleAuthenticateAlert()
          },
          action: toggleAuthenticateModal()
        )
        .alertView(
          isPresented: $isAuthenticateAlertShowing,
          title: .alertAccessOnlineServices,
          message: .alertAccessOnlineServicesMessage,
          actions: {
            Button(.okButton, role: .cancel) {}
          }
        )
      }
      .padding(.horizontal, SPACING_MEDIUM)
      .padding(.bottom, SPACING_MEDIUM)
    }
    .background(Theme.shared.color.background)
  }
}

#Preview {
  let state = HomeTabState(
    username: "Eudi User",
    contentHeaderConfig: .init(
      appIconAndTextData: AppIconAndTextData(
        appIcon: ThemeManager.shared.image.logoEuDigitalIndentityWallet
      )
    ),
    phase: .active,
    pendingBleModalAction: false
  )
  HomeTabViewContainer(
    viewState: state,
    isAuthenticateAlertShowing: .constant(false),
    isSignDocumentAlertShowing: .constant(false),
    oldestUnread: ActiveIssuerNotification(
      issuerName: "Skatteetaten",
      title: "Skattekortet ditt er klart",
      body: "En arbeidsgiver har bedt om skattekortet ditt.",
      actionURL: nil
    ),
    unreadCount: 2,
    toggleAuthenticateAlert: {},
    toggleAuthenticateModal: {},
    openSignDocument: {},
    toggleSignDocumentAlert: {},
    onMarkRead: { _ in },
    onDismiss: { _ in },
    onAddTestNotification: {}
  )
}
