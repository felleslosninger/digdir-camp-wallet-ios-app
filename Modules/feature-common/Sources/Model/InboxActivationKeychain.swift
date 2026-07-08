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
/// `registrationId` the backend uses to address this device's inbox. Note
/// what's deliberately NOT here: no bearer token, no session secret — the
/// thing that actually protects this device's messages is the Secure
/// Enclave private key in `SecureEnclaveMessagingKey`, which never leaves
/// the chip and so has nothing to steal from the Keychain in the first
/// place. `registrationId` is not sensitive on its own (it doesn't identify
/// the PID or decrypt anything), so plain UserDefaults is sufficient.
enum InboxActivationKeychain {

  private static let registrationIdKey = "inbox_activation_registration_id"

  static func markActivated(registrationId: String) {
    UserDefaults.standard.set(registrationId, forKey: registrationIdKey)
  }

  static var registrationId: String? {
    UserDefaults.standard.string(forKey: registrationIdKey)
  }

  static var isActivated: Bool {
    registrationId != nil
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: registrationIdKey)
  }
}
