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
      toggleAuthenticateAlert: { viewModel.toggleAuthenticateAlert() },
      onInPerson: { viewModel.onShare() },
      onOnline: { viewModel.onShowScanner() },
      openSignDocument: { viewModel.openSignDocument() },
      toggleSignDocumentAlert: { viewModel.toggleSignDocumentAlert() }
    )
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

private struct HomeTabViewContainer: View {

  let viewState: HomeTabState
  @Binding var isAuthenticateAlertShowing: Bool
  @Binding var isSignDocumentAlertShowing: Bool
  let toggleAuthenticateAlert: () -> Void
  let onInPerson: () -> Void
  let onOnline: () -> Void
  let openSignDocument: () -> Void
  let toggleSignDocumentAlert: () -> Void

  var body: some View {
    content()
  }

  @MainActor
  @ViewBuilder
  private func content() -> some View {
    VStack(alignment: .leading, spacing: SPACING_MEDIUM) {
      ContentHeaderView(
        config: viewState.contentHeaderConfig
      )
      .padding(.horizontal, SPACING_MEDIUM)

      Text(.authenticateAuthoriseTransactions)
        .typography(Theme.shared.font.bodyLarge)
        .foregroundStyle(Theme.shared.color.primaryLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SPACING_MEDIUM)
        .background(Theme.shared.color.groupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.shared.shape.small))
        .padding(.horizontal, SPACING_MEDIUM)

      WrapButtonView(
        title: .inPerson,
        onAction: onInPerson()
      )
      .padding(.horizontal, SPACING_MEDIUM)

      WrapButtonView(
        title: .online,
        onAction: onOnline()
      )
      .padding(.horizontal, SPACING_MEDIUM)

      Spacer()

      WrapButtonView(
        title: .learnMore,
        textColor: Theme.shared.color.accent,
        backgroundColor: .clear,
        onAction: toggleAuthenticateAlert()
      )
      .padding(.horizontal, SPACING_MEDIUM)
      .padding(.bottom, SPACING_MEDIUM)
      .alertView(
        isPresented: $isAuthenticateAlertShowing,
        title: .alertAccessOnlineServices,
        message: .alertAccessOnlineServicesMessage,
        actions: {
          Button(.okButton, role: .cancel) {}
        }
      )
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
    toggleAuthenticateAlert: {},
    onInPerson: {},
    onOnline: {},
    openSignDocument: {},
    toggleSignDocumentAlert: {}
  )
}
