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
import UIKit
import UserNotifications
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
            onSelect: { viewModel.select($0) }
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
      set: { newValue in
        if newValue == nil {
          viewModel.dismissSelected()
        }
      }
    )) { notification in
      IssuerNotificationDetailView(
        notification: notification,
        onMarkRead: {
          viewModel.markAsRead(id: notification.id)
        },
        onDismiss: {
          // Vi sletter ikke meldinger i denne innboks-prototypen.
        }
      )
    }
  }
}

// MARK: - Activation view

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

// MARK: - App badge helper

private enum InboxAppBadge {
  @MainActor
  static func update(unreadCount: Int) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let notificationsAreAllowed =
        settings.authorizationStatus == .authorized ||
        settings.authorizationStatus == .provisional ||
        settings.authorizationStatus == .ephemeral

      DispatchQueue.main.async {
        let badgeCount = notificationsAreAllowed ? unreadCount : 0

        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(badgeCount) { error in
            if let error {
              print("[InboxAppBadge] Failed to set badge count: \(error)")
            } else {
              print("[InboxAppBadge] Badge count set to \(badgeCount)")
            }
          }
        } else {
          UIApplication.shared.applicationIconBadgeNumber = badgeCount
          print("[InboxAppBadge] Badge count set to \(badgeCount)")
        }
      }
    }
  }
}

// MARK: - Real inbox container

private struct InboxTabViewContainer: View {

  let notifications: [ActiveIssuerNotification]
  let onSelect: (ActiveIssuerNotification) -> Void

  @State private var searchText: String = ""
  @AppStorage("inboxUnreadCount") private var inboxUnreadCount: Int = 0

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool {
    !trimmedSearchText.isEmpty
  }

  private var unreadCount: Int {
    notifications.filter { !$0.isRead }.count
  }

  private var visibleNotifications: [ActiveIssuerNotification] {
    let ordered = sortedNotifications(notifications)

    guard isSearching else {
      return ordered
    }

    return sortedNotifications(matchingNotifications(in: notifications))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SPACING_MEDIUM) {

        InboxSearchField(searchText: $searchText)

        Text("Offentlige varsler og meldinger fra lommeboken din.")
          .typography(Theme.shared.font.bodyMedium)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
          .padding(.horizontal, SPACING_MEDIUM)

        if notifications.isEmpty && !isSearching {
          EmptyInboxState(
            icon: "tray",
            title: "Ingen varsler",
            message: "Du har ingen varsler i lommeboken akkurat nå."
          )

        } else if visibleNotifications.isEmpty {
          EmptyInboxState(
            icon: "doc.text.magnifyingglass",
            title: "Ingen treff",
            message: "Fant ingen varsler som matcher «\(searchText)»."
          )

        } else {
          VStack(spacing: SPACING_SMALL) {
            ForEach(visibleNotifications) { notification in
              Button {
                onSelect(notification)
              } label: {
                InboxNotificationCard(notification: notification)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, SPACING_MEDIUM)
        }
      }
      .padding(.top, SPACING_MEDIUM)
    }
    .onAppear {
      updateUnreadCount()
    }
    .onChange(of: unreadCount) {
      updateUnreadCount()
    }
  }

  private func updateUnreadCount() {
    inboxUnreadCount = unreadCount

    Task { @MainActor in
      InboxAppBadge.update(unreadCount: unreadCount)
    }
  }

  private func sortedNotifications(_ source: [ActiveIssuerNotification]) -> [ActiveIssuerNotification] {
    // Demo: behold samme rekkefølge. Ikke flytt uleste meldinger øverst.
    source
  }

  private func matchingNotifications(in source: [ActiveIssuerNotification]) -> [ActiveIssuerNotification] {
    let senderMatches = source.filter { notification in
      notification.issuerName.containsWordStarting(with: trimmedSearchText)
    }

    if !senderMatches.isEmpty {
      return senderMatches
    }

    let titleMatches = source.filter { notification in
      notification.title.containsWordStarting(with: trimmedSearchText)
    }

    if !titleMatches.isEmpty {
      return titleMatches
    }

    return source.filter { notification in
      notification.issuerName.localizedCaseInsensitiveContains(trimmedSearchText) ||
      notification.title.localizedCaseInsensitiveContains(trimmedSearchText) ||
      notification.body.localizedCaseInsensitiveContains(trimmedSearchText)
    }
  }
}

// MARK: - JSON fallback container

private struct InboxPreviewInboxContainer: View {

  @State private var selectedMessage: InboxPreviewMessage?
  @State private var searchText: String = ""
  @State private var readMessageIds: Set<String> = []
  @AppStorage("inboxUnreadCount") private var inboxUnreadCount: Int = 0

  @State private var messages: [InboxPreviewMessage] = InboxPreviewMessageService.fetchMessages()

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool {
    !trimmedSearchText.isEmpty
  }

  private var unreadCount: Int {
    messages.filter { !isMessageRead($0) }.count
  }

  private var visibleMessages: [InboxPreviewMessage] {
    let ordered = sortedMessages(messages)

    guard isSearching else {
      return ordered
    }

    return sortedMessages(matchingMessages(in: messages))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SPACING_MEDIUM) {

        InboxSearchField(searchText: $searchText)

        Text("Offentlige varsler og meldinger fra lommeboken din.")
          .typography(Theme.shared.font.bodyMedium)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
          .padding(.horizontal, SPACING_MEDIUM)

        if messages.isEmpty && !isSearching {
          EmptyInboxState(
            icon: "tray",
            title: "Ingen varsler",
            message: "Du har ingen varsler i lommeboken akkurat nå."
          )

        } else if visibleMessages.isEmpty {
          EmptyInboxState(
            icon: "doc.text.magnifyingglass",
            title: "Ingen treff",
            message: "Fant ingen varsler som matcher «\(searchText)»."
          )

        } else {
          VStack(spacing: SPACING_SMALL) {
            ForEach(visibleMessages) { message in
              Button {
                openMessage(message)
              } label: {
                InboxPreviewMessageCard(
                  message: message,
                  isRead: isMessageRead(message)
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, SPACING_MEDIUM)
        }
      }
      .padding(.top, SPACING_MEDIUM)
    }
    .onAppear {
      updateUnreadCount()
    }
    .sheet(item: $selectedMessage) { message in
      InboxPreviewMessageDetailView(
        message: message,
        isRead: isMessageRead(message)
      )
    }
  }

  private func openMessage(_ message: InboxPreviewMessage) {
    readMessageIds.insert(message.id)
    updateUnreadCount()
    selectedMessage = message
  }

  private func isMessageRead(_ message: InboxPreviewMessage) -> Bool {
    message.isRead || readMessageIds.contains(message.id)
  }

  private func updateUnreadCount() {
    inboxUnreadCount = unreadCount

    Task { @MainActor in
      InboxAppBadge.update(unreadCount: unreadCount)
    }
  }

  private func sortedMessages(_ source: [InboxPreviewMessage]) -> [InboxPreviewMessage] {
    // Demo: behold samme rekkefølge. Ikke flytt uleste meldinger øverst.
    source
  }

  private func matchingMessages(in source: [InboxPreviewMessage]) -> [InboxPreviewMessage] {
    let senderMatches = source.filter { message in
      message.sender.containsWordStarting(with: trimmedSearchText)
    }

    if !senderMatches.isEmpty {
      return senderMatches
    }

    let titleMatches = source.filter { message in
      message.subject.containsWordStarting(with: trimmedSearchText)
    }

    if !titleMatches.isEmpty {
      return titleMatches
    }

    return source.filter { message in
      message.sender.localizedCaseInsensitiveContains(trimmedSearchText) ||
      message.subject.localizedCaseInsensitiveContains(trimmedSearchText) ||
      message.body.localizedCaseInsensitiveContains(trimmedSearchText)
    }
  }
}

// MARK: - Search field

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

// MARK: - Empty state

private struct EmptyInboxState: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: SPACING_MEDIUM) {
      Image(systemName: icon)
        .font(.system(size: 40))
        .foregroundStyle(Theme.shared.color.secondaryLabel)

      Text(title)
        .typography(Theme.shared.font.titleMedium)
        .foregroundStyle(Theme.shared.color.primaryLabel)

      Text(message)
        .typography(Theme.shared.font.bodyMedium)
        .foregroundStyle(Theme.shared.color.secondaryLabel)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, SPACING_LARGE)
    .padding(.top, SPACING_LARGE)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Real notification card

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
                .background(
                  Capsule()
                    .fill(Theme.shared.color.accent.opacity(0.15))
                )
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
        Label("Offentlig melding", systemImage: "checkmark.seal.fill")
          .font(.caption)
          .bold()
          .foregroundStyle(Theme.shared.color.accent)

        Spacer()
      }
    }
    .padding(SPACING_MEDIUM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(Theme.shared.color.secondaryBackground)
    )
  }
}

// MARK: - JSON preview model

private struct InboxPreviewMessageDTO: Decodable {
  let id: String
  let senderCn: String
  let subject: String
  let body: String
  let sentAt: String
  let status: String
}

private struct InboxPreviewMessage: Identifiable {
  let id: String
  let sender: String
  let subject: String
  let body: String
  let dateText: String
  let actionURL: URL?
  var deliveryStatus: InboxPreviewDeliveryStatus

  var isRead: Bool {
    deliveryStatus == .read
  }
}

private enum InboxPreviewDeliveryStatus: String {
  case undelivered = "ulevert"
  case delivered = "levert"
  case read = "lest"
  case unknown
}

private struct InboxPreviewMessageService {
  static func fetchMessages() -> [InboxPreviewMessage] {
    guard let url = Bundle.main.url(forResource: "inbox-messages", withExtension: "json") else {
      print("Fant ikke inbox-messages.json i app bundle. Bruker demo-meldinger.")
      return demoMessages()
    }

    do {
      let data = try Data(contentsOf: url)
      let messages = try JSONDecoder().decode([InboxPreviewMessageDTO].self, from: data)

      let mappedMessages: [InboxPreviewMessage] = messages.compactMap { dto -> InboxPreviewMessage? in
        let status = InboxPreviewDeliveryStatus(rawValue: dto.status.lowercased()) ?? .unknown

        guard status != .undelivered,
              status != .unknown else {
          return nil
        }

        return InboxPreviewMessage(
          id: dto.id,
          sender: dto.senderCn,
          subject: dto.subject,
          body: dto.body,
          dateText: dto.sentAt,
          actionURL: InboxPreviewTrustedActionCatalog.actionURL(for: dto.senderCn),
          deliveryStatus: status
        )
      }

      if mappedMessages.isEmpty {
        print("JSON ble lest, men ingen meldinger kunne vises. Bruker demo-meldinger.")
        return demoMessages()
      }

      return mappedMessages

    } catch {
      print("Klarte ikke å lese inbox-messages.json: \(error). Bruker demo-meldinger.")
      return demoMessages()
    }
  }

  private static func demoMessages() -> [InboxPreviewMessage] {
    [
      InboxPreviewMessage(
        id: "1",
        sender: "Statens vegvesen",
        subject: "Førerretten din er oppdatert",
        body: "Det har skjedd en endring i førerretten din. Varselet er verifisert mot tillitslisten.",
        dateText: "I dag",
        actionURL: InboxPreviewTrustedActionCatalog.actionURL(for: "Statens vegvesen"),
        deliveryStatus: .delivered
      ),
      InboxPreviewMessage(
        id: "2",
        sender: "Lånekassen",
        subject: "Ny melding om søknaden din",
        body: "Søknaden din er behandlet. Avsender og meldingsstatus er kontrollert i lommeboken.",
        dateText: "I går",
        actionURL: InboxPreviewTrustedActionCatalog.actionURL(for: "Lånekassen"),
        deliveryStatus: .delivered
      ),
      InboxPreviewMessage(
        id: "3",
        sender: "NAV",
        subject: "Melding fra NAV",
        body: "Du har fått en ny melding fra NAV. Åpne den trygge nettsiden for å lese mer.",
        dateText: "5. juli",
        actionURL: InboxPreviewTrustedActionCatalog.actionURL(for: "NAV"),
        deliveryStatus: .read
      ),
      InboxPreviewMessage(
        id: "4",
        sender: "Skatteetaten",
        subject: "Skattekortet ditt er klart",
        body: "Skattekortet ditt er klart. Logg inn hos Skatteetaten for å se detaljer.",
        dateText: "3. juli",
        actionURL: InboxPreviewTrustedActionCatalog.actionURL(for: "Skatteetaten"),
        deliveryStatus: .read
      )
    ]
  }
}

private struct InboxPreviewTrustedActionCatalog {
  static func actionURL(for senderCn: String) -> URL? {
    let sender = senderCn.lowercased()

    if sender.contains("lånekassen") {
      return URL(string: "https://www.lanekassen.no")
    }

    if sender.contains("statens vegvesen") {
      return URL(string: "https://www.vegvesen.no")
    }

    if sender.contains("skatteetaten") {
      return URL(string: "https://www.skatteetaten.no")
    }

    if sender.contains("nav") {
      return URL(string: "https://www.nav.no")
    }

    return nil
  }
}

// MARK: - JSON preview card

private struct InboxPreviewMessageCard: View {
  let message: InboxPreviewMessage
  let isRead: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: SPACING_SMALL) {

      HStack(alignment: .top) {
        if !isRead {
          Circle()
            .fill(Theme.shared.color.accent)
            .frame(width: 10, height: 10)
            .padding(.top, 5)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(message.sender)
              .typography(Theme.shared.font.bodySmall)
              .fontWeight(isRead ? .regular : .semibold)
              .foregroundStyle(Theme.shared.color.secondaryLabel)

            if !isRead {
              Text("Ulest")
                .font(.caption2)
                .bold()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                  Capsule()
                    .fill(Theme.shared.color.accent.opacity(0.15))
                )
                .foregroundStyle(Theme.shared.color.accent)
            }
          }

          Text(message.subject)
            .typography(isRead ? Theme.shared.font.bodyLarge : Theme.shared.font.titleSmall)
            .foregroundStyle(Theme.shared.color.primaryLabel)
        }

        Spacer()

        Text(message.dateText)
          .typography(Theme.shared.font.bodySmall)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
      }

      Text(message.body)
        .typography(Theme.shared.font.bodyMedium)
        .foregroundStyle(Theme.shared.color.secondaryLabel)
        .lineLimit(2)

      HStack(spacing: 8) {
        Label("Offentlig melding", systemImage: "checkmark.seal.fill")
          .font(.caption)
          .bold()
          .foregroundStyle(Theme.shared.color.accent)

        Spacer()
      }
    }
    .padding(SPACING_MEDIUM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(Theme.shared.color.secondaryBackground)
    )
  }
}

// MARK: - JSON preview detail

private struct InboxPreviewMessageDetailView: View {
  let message: InboxPreviewMessage
  let isRead: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SPACING_LARGE) {

        HStack {
          Image(systemName: "checkmark.seal.fill")
            .font(.title2)
            .foregroundStyle(Theme.shared.color.accent)

          Text("Offentlig melding")
            .typography(Theme.shared.font.titleSmall)
            .foregroundStyle(Theme.shared.color.accent)

          Spacer()

          if isRead {
            Label("Lest", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(Theme.shared.color.secondaryLabel)
          }
        }

        Text(message.subject)
          .typography(Theme.shared.font.titleMedium)
          .foregroundStyle(Theme.shared.color.primaryLabel)

        Text(readStatusDescription)
          .typography(Theme.shared.font.bodyMedium)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 14)
              .fill(Theme.shared.color.secondaryBackground)
          )

        VStack(alignment: .leading, spacing: 6) {
          Text("Avsender")
            .typography(Theme.shared.font.bodySmall)
            .foregroundStyle(Theme.shared.color.secondaryLabel)

          Text(message.sender)
            .typography(Theme.shared.font.bodyMedium)
            .foregroundStyle(Theme.shared.color.primaryLabel)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Dato")
            .typography(Theme.shared.font.bodySmall)
            .foregroundStyle(Theme.shared.color.secondaryLabel)

          Text(message.dateText)
            .typography(Theme.shared.font.bodyMedium)
            .foregroundStyle(Theme.shared.color.primaryLabel)
        }

        Divider()

        Text(message.body)
          .typography(Theme.shared.font.bodyMedium)
          .foregroundStyle(Theme.shared.color.primaryLabel)

        Divider()

        Text("Dette varselet vises som offentlig melding i prototypen. Senere kan dette kobles til avsenderkontroll, signatur eller tillitsliste.")
          .typography(Theme.shared.font.bodyMedium)
          .foregroundStyle(Theme.shared.color.secondaryLabel)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 14)
              .fill(Theme.shared.color.secondaryBackground)
          )

        if let actionURL = message.actionURL {
          Link(destination: actionURL) {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Image(systemName: "lock.shield.fill")
                Text("Åpne trygg nettside")
                  .bold()
              }

              Text(actionURL.host ?? "")
                .font(.caption)
                .foregroundStyle(Theme.shared.color.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
              RoundedRectangle(cornerRadius: 14)
                .fill(Theme.shared.color.secondaryBackground)
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(SPACING_LARGE)
    }
  }

  private var readStatusDescription: String {
    if isRead {
      return "Dette varselet er markert som lest. Det er ikke slettet, og kan fortsatt brukes som dokumentasjon."
    }

    switch message.deliveryStatus {
    case .delivered:
      return "Dette varselet er levert til innboksen, men ikke åpnet ennå."
    case .read:
      return "Dette varselet er markert som lest. Det er ikke slettet, og kan fortsatt brukes som dokumentasjon."
    case .undelivered:
      return "Dette varselet er ikke levert ennå."
    case .unknown:
      return "Status for dette varselet er ukjent."
    }
  }
}

// MARK: - Detail-view compatibility

public enum InboxNotificationTrustStatus {
  case publicMessage

  var title: String {
    "Offentlig melding"
  }

  var icon: String {
    "checkmark.seal.fill"
  }

  var color: Color {
    Theme.shared.color.accent
  }
}

extension ActiveIssuerNotification {
  var trustStatus: InboxNotificationTrustStatus {
    .publicMessage
  }
}

// MARK: - Search helper

extension String {
  func containsWordStarting(with searchText: String) -> Bool {
    let words = self
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)

    let query = searchText.lowercased()

    return words.contains { word in
      word.hasPrefix(query)
    }
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
    onSelect: { _ in }
  )
}
