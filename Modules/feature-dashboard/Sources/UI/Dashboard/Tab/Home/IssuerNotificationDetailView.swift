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

struct ActiveIssuerNotification: Identifiable, Codable {
  let id: String
  let issuerName: String
  let title: String
  let body: String
  let actionURL: URL?
  let receivedAt: Date
  var isRead: Bool

  init(issuerName: String, title: String, body: String, actionURL: URL?) {
    self.id = UUID().uuidString
    self.issuerName = issuerName
    self.title = title
    self.body = body
    self.actionURL = actionURL
    self.receivedAt = Date()
    self.isRead = false
  }
}

struct IssuerNotificationDetailView: View {

  let notification: ActiveIssuerNotification
  let onMarkRead: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: SPACING_LARGE) {

      HStack {
        Image(systemName: "bell.badge.fill")
          .foregroundStyle(Theme.shared.color.accent)
          .font(.system(size: 24))
        VStack(alignment: .leading, spacing: 2) {
          Text(notification.issuerName)
            .typography(Theme.shared.font.titleMedium)
            .foregroundStyle(Theme.shared.color.primaryLabel)
          Text(notification.receivedAt, style: .date)
            .typography(Theme.shared.font.bodySmall)
            .foregroundStyle(Theme.shared.color.secondaryLabel)
        }
        Spacer()
      }

      Divider()

      Text(notification.title)
        .typography(Theme.shared.font.titleSmall)
        .foregroundStyle(Theme.shared.color.primaryLabel)

      Text(notification.body)
        .typography(Theme.shared.font.bodyLarge)
        .foregroundStyle(Theme.shared.color.secondaryLabel)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()

      if let url = notification.actionURL {
        Link(destination: url) {
          Text("Gå til \(notification.issuerName)")
            .typography(Theme.shared.font.bodyLarge)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .padding(SPACING_MEDIUM)
            .background(Theme.shared.color.accent)
            .foregroundStyle(Theme.shared.color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
      }

      Button {
        onDismiss()
      } label: {
        Text("Slett melding")
          .typography(Theme.shared.font.bodyLarge)
          .fontWeight(.medium)
          .frame(maxWidth: .infinity)
          .padding(SPACING_MEDIUM)
          .background(Theme.shared.color.secondaryBackground)
          .foregroundStyle(Theme.shared.color.primaryLabel)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }
    }
    .padding(SPACING_LARGE)
    .background(Theme.shared.color.background)
    .onAppear {
      onMarkRead()
    }
  }
}
