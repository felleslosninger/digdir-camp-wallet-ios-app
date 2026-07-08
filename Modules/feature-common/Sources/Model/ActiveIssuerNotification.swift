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

public struct ActiveIssuerNotification: Identifiable, Codable {
  public let id: String
  public let issuerName: String
  public let title: String
  public let body: String
  public let actionURL: URL?
  public let receivedAt: Date
  public var isRead: Bool

  public init(issuerName: String, title: String, body: String, actionURL: URL?) {
    self.id = UUID().uuidString
    self.issuerName = issuerName
    self.title = title
    self.body = body
    self.actionURL = actionURL
    self.receivedAt = Date()
    self.isRead = false
  }
}
