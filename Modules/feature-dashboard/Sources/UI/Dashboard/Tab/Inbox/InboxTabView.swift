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

// MARK: - Message list (search + cards, ported from the standalone
// InboxMockTabView UI prototype and adapted to run on the real,
// backend-wired `ActiveIssuerNotification` data instead of mock JSON).

private struct InboxTabViewContainer: View {

  let notifications: [ActiveIssuerNotification]
  let onSelect: (ActiveIssuerNotification) -> Void
  let onDismiss: (String) -> Void

  @State private var searchText: String = ""

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool {
    !trimmedSearchText.isEmpty
  }

  private var visibleNotifications: [ActiveIssuerNotification] {
    let sorted = sortedNotifications(notifications)
    guard isSearching else { return sorted }
    return sortedNotifications(matchingNotifications(in: notifications))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SPACING_MEDIUM) {
        InboxSearchField(searchText: $searchText)

        if notifications.isEmpty && !isSearching {
          emptyState
        } else if visibleNotifications.isEmpty {
          noSearchResultsState
        } else {
          VStack(spacing: SPACING_SMALL) {
            ForEach(visibleNotifications) { notification in
              Button {
                onSelect(notification)
              } label: {
                InboxNotificationCard(notification: notification)
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button(role: .destructive) {
                  onDismiss(notification.id)
                } label: {
                  Label { Text(.deleteDocument) } icon: { Image(systemName: "trash") }
                }
              }
            }
          }
          .padding(.horizontal, SPACING_MEDIUM)
        }
      }
      .padding(.top, SPACING_MEDIUM)
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

  @ViewBuilder
  private var noSearchResultsState: some View {
    VStack(spacing: SPACING_MEDIUM) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 40))
        .foregroundStyle(Theme.shared.color.secondaryLabel)
      Text("Ingen treff")
        .typography(Theme.shared.font.titleMedium)
        .foregroundStyle(Theme.shared.color.primaryLabel)
      Text("Fant ingen varsler som matcher «\(searchText)».")
        .typography(Theme.shared.font.bodyMedium)
        .foregroundStyle(Theme.shared.color.secondaryLabel)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, SPACING_LARGE)
    .padding(.top, SPACING_LARGE)
  }

  private func sortedNotifications(_ source: [ActiveIssuerNotification]) -> [ActiveIssuerNotification] {
    source.sorted { first, second in
      if first.isRead == second.isRead { return first.receivedAt > second.receivedAt }
      return !first.isRead && second.isRead
    }
  }

  private func matchingNotifications(in source: [ActiveIssuerNotification]) -> [ActiveIssuerNotification] {
    source.filter { notification in
      notification.issuerName.localizedCaseInsensitiveContains(trimmedSearchText) ||
      notification.title.localizedCaseInsensitiveContains(trimmedSearchText) ||
      notification.body.localizedCaseInsensitiveContains(trimmedSearchText)
    }
  }
}

private struct InboxSearchField: View {
  @Binding var searchText: String

  var body: some View {
    HStack(spacing: SPACING_SMALL) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Theme.shared.color.secondaryLabel)

      TextField("Søk i varsler", text: $searchText)
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(Theme.shared.color.secondaryLabel)
        }
      }
    }
    .padding(SPACING_MEDIUM)
    .background(
      RoundedRectangle(cornerRadius: 16)
        .fill(Theme.shared.color.secondaryBackground)
    )
    .padding(.horizontal, SPACING_MEDIUM)
  }
}

private struct InboxNotificationCard: View {
  let notification: ActiveIssuerNotification

  var body: some View {
    VStack(alignment: .leading, spacing: SPACING_SMALL) {
      HStack(alignment: .top) {
        if !notification.isRead {
          Circle()
            .fill(Theme.shared.color.accent)
            .frame(width: 10, height: 10)
            .padding(.top, 5)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(notification.issuerName)
              .typography(Theme.shared.font.bodySmall)
              .fontWeight(notification.isRead ? .regular : .semibold)
              .foregroundStyle(Theme.shared.color.secondaryLabel)

            if !notification.isRead {
              Text("Ulest")
                .font(.caption2)
                .bold()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.shared.color.accent.opacity(0.15)))
                .foregroundStyle(Theme.shared.color.accent)
            }
          }

          Text(notification.title)
            .typography(notification.isRead ? Theme.shared.font.bodyLarge : Theme.shared.font.titleSmall)
            .foregroundStyle(Theme.shared.color.primaryLabel)
        }

        Spacer()

        Text(notification.receivedAt, style: .date)
          .typography(Theme.shared.font.bodySmall)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
      }

      Text(notification.body)
        .typography(Theme.shared.font.bodyMedium)
        .foregroundStyle(Theme.shared.color.secondaryLabel)
        .lineLimit(2)

      HStack(spacing: 8) {
        Label(notification.trustStatus.title, systemImage: notification.trustStatus.icon)
          .font(.caption)
          .bold()
          .foregroundStyle(notification.trustStatus.color)
        Spacer()
      }
    }
    .padding(SPACING_MEDIUM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.shared.color.secondaryBackground))
  }
}

// MARK: - Trust status heuristic (prototype only)
//
// Ported from the InboxMockTabView prototype. Not backed by a real trust
// list yet — inferred from keywords in the notification text. Replace with
// a real signal (issuer signature / trust list lookup) before this is
// anything more than a demo.
public enum InboxNotificationTrustStatus {
  case verified
  case revoked
  case expired

  var title: String {
    switch self {
    case .verified: return "Verifisert"
    case .revoked: return "Tilbakekalt"
    case .expired: return "Utløpt"
    }
  }

  var icon: String {
    switch self {
    case .verified: return "checkmark.seal.fill"
    case .revoked: return "xmark.seal.fill"
    case .expired: return "clock.fill"
    }
  }

  var color: Color {
    switch self {
    case .verified: return .blue
    case .revoked: return .red
    case .expired: return .gray
    }
  }
}

extension ActiveIssuerNotification {
  var trustStatus: InboxNotificationTrustStatus {
    let text = "\(title) \(body)".lowercased()
    if text.contains("tilbakekalt") { return .revoked }
    if text.contains("utløpt") { return .expired }
    return .verified
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
