import SwiftUI

struct InboxTabView: View {

  @State private var selectedMessage: InboxTabMessage?
  @State private var searchText: String = ""
  @AppStorage("inboxUnreadCount") private var inboxUnreadCount: Int = 0

  @State private var messages: [InboxTabMessage] = InboxMockMessageService.fetchMessages()

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool {
    !trimmedSearchText.isEmpty
  }

  private var visibleMessages: [InboxTabMessage] {
    guard isSearching else {
      return sortedMessages(messages)
    }

    return sortedMessages(matchingMessages(in: messages))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {

        SearchFieldView(searchText: $searchText)

        Text("Offentlige varsler og meldinger fra lommeboken din.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.horizontal)

        if messages.isEmpty && !isSearching {
          EmptyInboxView(
            icon: "tray",
            title: "Ingen varsler",
            message: "Du har ingen varsler i lommeboken akkurat nå."
          )
          .padding(.horizontal)
          .padding(.top, 24)

        } else if visibleMessages.isEmpty {
          EmptyInboxView(
            icon: "doc.text.magnifyingglass",
            title: "Ingen treff",
            message: "Fant ingen bevis eller varsler som matcher «\(searchText)»."
          )
          .padding(.horizontal)
          .padding(.top, 24)

        } else {
          VStack(spacing: 12) {
            ForEach(visibleMessages) { message in
              Button {
                openMessage(message)
              } label: {
                InboxTabMessageCard(message: message)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal)
        }
      }
      .padding(.top)
    }
    .onAppear {
      updateUnreadCount()
    }
    .sheet(item: $selectedMessage) { message in
      InboxTabMessageDetailView(message: message)
    }
  }

  private func sortedMessages(_ source: [InboxTabMessage]) -> [InboxTabMessage] {
    source.sorted { first, second in
      if first.isRead == second.isRead {
        return first.id < second.id
      }

      return !first.isRead && second.isRead
    }
  }

  private func matchingMessages(in source: [InboxTabMessage]) -> [InboxTabMessage] {
    let senderMatches = source.filter { message in
      message.sender.containsWordStarting(with: trimmedSearchText)
    }

    if !senderMatches.isEmpty {
      return senderMatches
    }

    let subjectMatches = source.filter { message in
      message.subject.containsWordStarting(with: trimmedSearchText)
    }

    if !subjectMatches.isEmpty {
      return subjectMatches
    }

    return source.filter { message in
      message.sender.localizedCaseInsensitiveContains(trimmedSearchText) ||
      message.subject.localizedCaseInsensitiveContains(trimmedSearchText) ||
      message.body.localizedCaseInsensitiveContains(trimmedSearchText) ||
      message.dateText.localizedCaseInsensitiveContains(trimmedSearchText) ||
      message.trustStatus.title.localizedCaseInsensitiveContains(trimmedSearchText) ||
      message.type.title.localizedCaseInsensitiveContains(trimmedSearchText)
    }
  }

  private func openMessage(_ message: InboxTabMessage) {
    guard let index = messages.firstIndex(where: { $0.id == message.id }) else {
      return
    }

    messages[index].deliveryStatus = .read
    updateUnreadCount()
    selectedMessage = messages[index]

    // Senere:
    // Her skal appen sende beskjed til backend:
    // PATCH /inbox/messages/{id}/read
  }

  private func updateUnreadCount() {
    inboxUnreadCount = messages.filter { !$0.isRead }.count
  }
}

struct InboxMessageDTO: Decodable {
  let id: String
  let senderCn: String
  let subject: String
  let body: String
  let sentAt: String
  let status: String
}

struct InboxMockMessageService {
  static func fetchMessages() -> [InboxTabMessage] {
    guard let url = Bundle.main.url(forResource: "inbox-messages", withExtension: "json") else {
      print("Fant ikke inbox-messages.json i app bundle.")
      return []
    }

    do {
      let data = try Data(contentsOf: url)
      let backendMessages = try JSONDecoder().decode([InboxMessageDTO].self, from: data)

      return backendMessages.compactMap { dto in
        dto.toInboxTabMessage()
      }
    } catch {
      print("Klarte ikke å lese eller dekode inbox-messages.json: \(error)")
      return []
    }
  }
}

extension InboxMessageDTO {
  func toInboxTabMessage() -> InboxTabMessage? {
    let deliveryStatus = InboxDeliveryStatus(rawValue: status.lowercased()) ?? .unknown

    guard deliveryStatus != .undelivered,
          deliveryStatus != .unknown else {
      return nil
    }

    let trustedAction = InboxTrustedActionCatalog.action(for: senderCn)

    return InboxTabMessage(
      id: id,
      sender: senderCn,
      subject: subject,
      body: body,
      dateText: sentAt,
      trustStatus: trustStatusForPrototype,
      type: .messageSystem,
      trustedAction: trustedAction,
      deliveryStatus: deliveryStatus
    )
  }

  private var trustStatusForPrototype: InboxTrustStatus {
    let text = "\(subject) \(body)".lowercased()

    if text.contains("tilbakekalt") {
      return .revoked
    }

    if text.contains("utløpt") {
      return .expired
    }

    return .verified
  }
}

enum InboxDeliveryStatus: String {
  case undelivered = "ulevert"
  case delivered = "levert"
  case read = "lest"
  case unknown

  var isRead: Bool {
    self == .read
  }
}

struct InboxTrustedAction {
  let title: String
  let url: URL?
  let domain: String
}

struct InboxTrustedActionCatalog {
  static func action(for senderCn: String) -> InboxTrustedAction? {
    let sender = senderCn.lowercased()

    if sender.contains("lånekassen") {
      return InboxTrustedAction(
        title: "Åpne Lånekassen",
        url: URL(string: "https://www.lanekassen.no"),
        domain: "lanekassen.no"
      )
    }

    if sender.contains("statens vegvesen") {
      return InboxTrustedAction(
        title: "Åpne Statens vegvesen",
        url: URL(string: "https://www.vegvesen.no"),
        domain: "vegvesen.no"
      )
    }

    if sender.contains("skatteetaten") {
      return InboxTrustedAction(
        title: "Åpne Skatteetaten",
        url: URL(string: "https://www.skatteetaten.no"),
        domain: "skatteetaten.no"
      )
    }

    if sender.contains("nav") {
      return InboxTrustedAction(
        title: "Åpne NAV",
        url: URL(string: "https://www.nav.no"),
        domain: "nav.no"
      )
    }

    return nil
  }
}

struct SearchFieldView: View {
  @Binding var searchText: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Søk i bevis og varsler", text: $searchText)
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 16)
        .fill(Color(.secondarySystemBackground))
    )
    .padding(.horizontal)
  }
}

struct EmptyInboxView: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.largeTitle)
        .foregroundStyle(.secondary)

      Text(title)
        .font(.headline)

      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding()
  }
}

struct InboxTabMessage: Identifiable {
  let id: String
  let sender: String
  let subject: String
  let body: String
  let dateText: String
  let trustStatus: InboxTrustStatus
  let type: InboxTabMessageType
  let trustedAction: InboxTrustedAction?
  var deliveryStatus: InboxDeliveryStatus

  var isRead: Bool {
    deliveryStatus == .read
  }
}

enum InboxTrustStatus: Equatable {
  case verified
  case revoked
  case expired

  var title: String {
    switch self {
    case .verified:
      return "Verifisert"
    case .revoked:
      return "Tilbakekalt"
    case .expired:
      return "Utløpt"
    }
  }

  var icon: String {
    switch self {
    case .verified:
      return "checkmark.seal.fill"
    case .revoked:
      return "xmark.seal.fill"
    case .expired:
      return "clock.fill"
    }
  }

  var color: Color {
    switch self {
    case .verified:
      return .blue
    case .revoked:
      return .red
    case .expired:
      return .gray
    }
  }
}

enum InboxTabMessageType {
  case digitalCredential
  case messageSystem

  var title: String {
    switch self {
    case .digitalCredential:
      return "Digitalt varselbevis"
    case .messageSystem:
      return "Offentlig melding"
    }
  }
}

struct InboxTabMessageCard: View {
  let message: InboxTabMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {

      HStack(alignment: .top) {
        if !message.isRead {
          Circle()
            .fill(Color.blue)
            .frame(width: 10, height: 10)
            .padding(.top, 5)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(message.sender)
              .font(.subheadline)
              .fontWeight(message.isRead ? .regular : .semibold)
              .foregroundStyle(.secondary)

            if !message.isRead {
              Text("Ulest")
                .font(.caption2)
                .bold()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                  Capsule()
                    .fill(Color.blue.opacity(0.15))
                )
                .foregroundStyle(.blue)
            }
          }

          Text(message.subject)
            .font(.headline)
            .fontWeight(message.isRead ? .regular : .bold)
            .foregroundStyle(.primary)
        }

        Spacer()

        Text(message.dateText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(message.body)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      HStack(spacing: 8) {
        Label(message.trustStatus.title, systemImage: message.trustStatus.icon)
          .font(.caption)
          .bold()
          .foregroundStyle(message.trustStatus.color)

        Spacer()

        Text(message.type.title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(Color(.secondarySystemBackground))
    )
  }
}

struct InboxTabMessageDetailView: View {
  let message: InboxTabMessage

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {

        HStack {
          Image(systemName: message.trustStatus.icon)
            .font(.title2)
            .foregroundStyle(message.trustStatus.color)

          Text(message.trustStatus.title)
            .font(.headline)
            .foregroundStyle(message.trustStatus.color)

          Spacer()

          if message.isRead {
            Label("Lest", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text(message.subject)
          .font(.title2)
          .bold()

        Text(readStatusDescription)
          .font(.subheadline)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 14)
              .fill(Color(.secondarySystemBackground))
          )

        VStack(alignment: .leading, spacing: 6) {
          Text("Avsender")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text(message.sender)
            .font(.body)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Dato")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text(message.dateText)
            .font(.body)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Type")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text(message.type.title)
            .font(.body)
        }

        Divider()

        Text(message.body)
          .font(.body)

        Divider()

        Text(trustStatusDescription)
          .font(.subheadline)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 14)
              .fill(Color(.secondarySystemBackground))
          )

        if message.trustStatus == .verified,
           let trustedAction = message.trustedAction,
           let trustedURL = trustedAction.url {

          Link(destination: trustedURL) {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Image(systemName: "lock.shield.fill")
                Text(trustedAction.title)
                  .bold()
              }

              Text("Betrodd domene: \(trustedAction.domain)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
              RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding()
    }
  }

  private var readStatusDescription: String {
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

  private var trustStatusDescription: String {
    switch message.trustStatus {
    case .verified:
      return "Dette varselet vises som verifisert i prototypen. Senere bør dette baseres på avsender, signatur eller tillitsliste."
    case .revoked:
      return "Dette varselet er tilbakekalt eller erstattet av en nyere versjon."
    case .expired:
      return "Dette varselet er utløpt og bør ikke brukes som gyldig informasjon."
    }
  }
}

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
