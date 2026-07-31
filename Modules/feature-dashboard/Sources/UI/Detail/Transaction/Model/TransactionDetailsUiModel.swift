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
import logic_ui
import logic_core
import logic_business
import logic_resources

public struct TransactionDetailsUiModel: Equatable, Identifiable, Sendable {

  public let id: String
  public let transactionDetailsCardData: TransactionDetailsCardData
  public let items: [GenericListItemSection]
}

extension TransactionDetailsUiModel {
  static func mock() -> TransactionDetailsUiModel {
    TransactionDetailsUiModel(
      id: "id",
      transactionDetailsCardData: TransactionDetailsCardData.mock(),
      items: [
        .init(
          id: "pid",
          title: "PID",
          listItems: []
        )
      ]
    )
  }
}

extension TransactionLogItem {
  func toUiModel() -> TransactionDetailsUiModel {

    var transactionTypeLabel: TransactionType {
      return switch transactionLogData {
      case .presentation:
          .presentation
      case .issuance:
          .issuance
      case .signing:
          .signing
      case .deletion:
          .deletion
      }
    }

    var transactionStatus: TransactionStatus? {
      return switch transactionLogData {
      case .presentation(let log):
        log.status.mapToTransactionStatus()
      case .issuance, .signing, .deletion:
        nil
      }
    }

    var transactionDateLabel: LocalizableStringKey {
      return switch transactionLogData {
      case .presentation(let log):
        .custom(log.timestamp.formattedTimestamp().toString)
      case .issuance, .signing, .deletion:
        .custom("")
      }
    }

    var relyingPartyData: TransactionLog.RelyingParty? {
      return switch self.transactionLogData {
      case .presentation(let log):
        log.relyingParty
      case .issuance, .signing, .deletion:
        nil
      }
    }

    var items: [GenericListItemSection] {
      switch self.transactionLogData {
      case .presentation(let log):
        if !log.documents.isEmpty {
          return log.documents.transformToTransactionListItemSections()
        }
        return rawRequest?.zkClaimSections() ?? []
      case .issuance, .signing, .deletion:
        return []
      }
    }

    return .init(
      id: self.id,
      transactionDetailsCardData: TransactionDetailsCardData(
        transactionTypeLabel: transactionTypeLabel.typeTitle,
        transactionStatusLabel: transactionStatus?.statusTitle ?? .custom(""),
        transactionIsCompleted: transactionStatus == .completed,
        transactionDate: transactionDateLabel,
        relyingPartyName: .custom(relyingPartyData?.name ?? ""),
        relyingPartyIsVerified: relyingPartyData?.isVerified,
        claimedVerifierName: rawRequest?.extractClientId()
      ),
      items: items
    )
  }
}

extension DocClaimsDecodable {
  func transformToTransactionListItemSection() -> GenericListItemSection {
    return .init(
      id: self.id,
      title: self.displayName.ifNilOrEmpty { self.docType },
      listItems: self.parseClaim(
        documentId: self.id,
        isSensitive: false,
        input: self.docClaims
      )
    )
  }
}

extension Array where Element == DocClaimsModel {
  func transformToTransactionListItemSections() -> [GenericListItemSection] {
    return self.map { $0.transformToTransactionListItemSection() }
  }
}

private extension Data {
  /// Extracts the DCQL credentials array from rawRequest, handling both
  /// the old format (bare DCQL JSON) and the new wrapper { dcql: {...}, clientId: "..." }.
  private func dcqlCredentials() -> [[String: Any]]? {
    guard let json = try? JSONSerialization.jsonObject(with: self) as? [String: Any] else { return nil }
    if let wrapped = json["dcql"] as? [String: Any] {
      return wrapped["credentials"] as? [[String: Any]]
    }
    return json["credentials"] as? [[String: Any]]
  }

  /// Extracts the self-reported client_id URL, stripping the redirect_uri prefix(es).
  func extractClientId() -> String? {
    guard
      let json = try? JSONSerialization.jsonObject(with: self) as? [String: Any],
      var raw = json["clientId"] as? String
    else { return nil }
    for prefix in ["redirect_uri:redirect_uri:", "redirect_uri:"] {
      if raw.hasPrefix(prefix) { raw = String(raw.dropFirst(prefix.count)); break }
    }
    return raw.isEmpty ? nil : raw
  }

  /// Parses DCQL request bytes into DATA SHARED display sections.
  /// Used as fallback when a ZK proof response has no decoded claims.
  func zkClaimSections() -> [GenericListItemSection] {
    guard let credentials = dcqlCredentials() else { return [] }

    return credentials.compactMap { cred in
      let credId = cred["id"] as? String ?? UUID().uuidString
      let meta = cred["meta"] as? [String: Any]
      let docType = meta?["doctype_value"] as? String ?? credId
      let rawClaims = cred["claims"] as? [[String: Any]] ?? []

      let listItems: [GenericExpandableItem] = rawClaims.compactMap { claim in
        guard let path = claim["path"] as? [String], let attrName = path.last else { return nil }
        let displayName = attrName.replacingOccurrences(of: "_", with: " ")
        return .single(.init(
          collapsed: ListItemData(mainContent: .text(.custom(displayName))),
          domainModel: nil
        ))
      }

      guard !listItems.isEmpty else { return nil }
      return GenericListItemSection(id: credId, title: docType, listItems: listItems)
    }
  }
}
