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
import feature_common

struct InboxTabView<Router: RouterHost>: View {

  @State private var viewModel: InboxTabViewModel<Router>

  init(with viewModel: InboxTabViewModel<Router>) {
    self._viewModel = State(wrappedValue: viewModel)
  }

  var body: some View {
    Group {
      if viewModel.viewState.isActivated {
        InboxTabViewContainer(
          notifications: viewModel.viewState.notifications,
          onSelect: { viewModel.select($0) },
          onDismiss: { viewModel.delete(id: $0) }
        )
      } else {
        InboxActivationView(
          isActivating: viewModel.viewState.isActivating,
          errorMessage: viewModel.viewState.activationError,
          onActivate: { viewModel.activate() }
        )
      }
    }
    .onAppear {
      viewModel.onAppear()
    }
    .sheet(item: Binding(
      get: { viewModel.viewState.selected },
      set: { newValue in if newValue == nil { viewModel.dismissSelected() } }
    )) { notification in
      IssuerNotificationDetailView(
        notification: notification,
        onMarkRead: { viewModel.markAsRead(id: notification.id) },
        onDismiss: { viewModel.delete(id: notification.id) }
      )
    }
  }
}

private struct InboxActivationView: View {

  let isActivating: Bool
  let errorMessage: String?
  let onActivate: () -> Void

  var body: some View {
    VStack(spacing: SPACING_MEDIUM) {
      Spacer()
      Image(systemName: "lock.shield")
        .font(.system(size: 40))
        .foregroundStyle(Theme.shared.color.accent)
      Text(.inboxActivationTitle)
        .typography(Theme.shared.font.titleMedium)
        .foregroundStyle(Theme.shared.color.primaryLabel)
        .multilineTextAlignment(.center)
      Text(.inboxActivationDescription)
        .typography(Theme.shared.font.bodyMedium)
        .foregroundStyle(Theme.shared.color.secondaryLabel)
        .multilineTextAlignment(.center)

      if let errorMessage {
        Text(errorMessage)
          .typography(Theme.shared.font.bodySmall)
          .foregroundStyle(Theme.shared.color.red)
          .multilineTextAlignment(.center)
      }

      Button {
        onActivate()
      } label: {
        if isActivating {
          ProgressView()
        } else {
          Text(.inboxActivationButton)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isActivating)

      Spacer()
    }
    .padding(SPACING_LARGE)
    .frame(maxWidth: .infinity)
  }
}

private struct InboxTabViewContainer: View {

  let notifications: [ActiveIssuerNotification]
  let onSelect: (ActiveIssuerNotification) -> Void
  let onDismiss: (String) -> Void

  var body: some View {
    if notifications.isEmpty {
      emptyState
    } else {
      List {
        ForEach(notifications) { notification in
          Button {
            onSelect(notification)
          } label: {
            row(for: notification)
          }
          .buttonStyle(.plain)
          .swipeActions {
            Button(role: .destructive) {
              onDismiss(notification.id)
            } label: {
              Text(.deleteDocument)
            }
          }
        }
      }
      .listStyle(.plain)
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    VStack(spacing: SPACING_MEDIUM) {
      Spacer()
      Image(systemName: "tray")
        .font(.system(size: 40))
        .foregroundStyle(Theme.shared.color.secondaryLabel)
      Text(.inboxEmptyTitle)
        .typography(Theme.shared.font.titleMedium)
        .foregroundStyle(Theme.shared.color.primaryLabel)
      Text(.inboxEmptyDescription)
        .typography(Theme.shared.font.bodyMedium)
        .foregroundStyle(Theme.shared.color.secondaryLabel)
        .multilineTextAlignment(.center)
      Spacer()
    }
    .padding(SPACING_LARGE)
    .frame(maxWidth: .infinity)
  }

  private func row(for notification: ActiveIssuerNotification) -> some View {
    HStack(alignment: .top, spacing: SPACING_MEDIUM) {
      Image(systemName: notification.isRead ? "envelope.open" : "envelope.badge.fill")
        .foregroundStyle(notification.isRead ? Theme.shared.color.secondaryLabel : Theme.shared.color.accent)
        .font(.system(size: 20))
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 2) {
        Text(notification.issuerName)
          .typography(Theme.shared.font.bodySmall)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
        Text(notification.title)
          .typography(notification.isRead ? Theme.shared.font.bodyLarge : Theme.shared.font.titleSmall)
          .foregroundStyle(Theme.shared.color.primaryLabel)
        Text(notification.body)
          .typography(Theme.shared.font.bodyMedium)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
          .lineLimit(2)
      }
    }
    .padding(.vertical, SPACING_SMALL)
  }
}

#Preview {
  let notifications: [ActiveIssuerNotification] = [
    ActiveIssuerNotification(
      issuerName: "Skatteetaten",
      title: "Skattekortet ditt er klart",
      body: "En arbeidsgiver har bedt om skattekortet ditt. Logg inn på Skatteetaten for å se detaljer.",
      actionURL: URL(string: "https://www.skatteetaten.no/person/")
    )
  ]
  InboxTabViewContainer(
    notifications: notifications,
    onSelect: { _ in },
    onDismiss: { _ in }
  )
}
