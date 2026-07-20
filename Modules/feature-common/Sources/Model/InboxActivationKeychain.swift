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

/// Tracks whether the one-time key binding has completed, and the opaque
/// `registrationId` the backend uses to address this device's inbox.
/// `registrationId` is not sensitive on its own, so plain UserDefaults is
/// sufficient for this prototype.
enum InboxActivationKeychain {

  private static let registrationIdKey = "inbox_activation_registration_id"

  static func markActivated(registrationId: String) {
    print("[InboxActivationKeychain] Saving registrationId: \(registrationId)")
    UserDefaults.standard.set(registrationId, forKey: registrationIdKey)
  }

  static var registrationId: String? {
    let value = UserDefaults.standard.string(forKey: registrationIdKey)
    print("[InboxActivationKeychain] Loaded registrationId: \(value ?? "nil")")
    return value
  }

  static var isActivated: Bool {
    registrationId != nil
  }

  static func clear() {
    print("[InboxActivationKeychain] Clearing registrationId")
    UserDefaults.standard.removeObject(forKey: registrationIdKey)
  }
}
