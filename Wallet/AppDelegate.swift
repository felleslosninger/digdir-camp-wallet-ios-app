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
import UIKit
@preconcurrency import UserNotifications
import logic_assembly
import logic_core
import feature_common
import SDWebImageSVGCoder

class AppDelegate: UIResponder, UIApplicationDelegate {

  private lazy var analyticsController: AnalyticsController = DIGraph.shared.resolver.force(AnalyticsController.self)
  private lazy var revocationWorkManager: RevocationWorkManager = DIGraph.shared.resolver.force(RevocationWorkManager.self)
  private lazy var reIssuanceWorkManager: ReIssuanceWorkManager = DIGraph.shared.resolver.force(ReIssuanceWorkManager.self)

  private let inboxShouldRefreshNotificationName = Notification.Name("inboxShouldRefresh")

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {

    // Initialize Reporting
    initializeReporting()

    // Initialize Workers
    initializeWorkers()

    // Register the SVG coder so SDWebImage can decode & render .svg images
    registerSvgCoderToSdImage()

    // Let AppDelegate handle notification callbacks while app is foregrounded / opened from notification
    UNUserNotificationCenter.current().delegate = self

    // Request permission for visible push notifications (banner, sound, badge)
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

    // Register device token with APNs
    application.registerForRemoteNotifications()

    return true
  }

  func application(
    _ application: UIApplication,
    shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
  ) -> Bool {
    switch extensionPointIdentifier {
    case UIApplication.ExtensionPointIdentifier.keyboard:
      return false
    default:
      return true
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()

    print("[APNs] Got device token: \(token)")

    UserDefaults.standard.set(token, forKey: "apns_device_token")

    Task {
      print("[APNs] Sending token to backend...")

      await MessagingBackend.registerDevice(token: token)

      print("[APNs] registerDevice call done")

      // The inbox activation is a separate, PID-bound registration.
      // Only refresh it here if the inbox is already activated.
      guard InboxActivationBackend.isActivated else {
        return
      }

      await InboxActivationBackend.refreshPushToken(token)

      print("[Inbox] refreshed push token for existing activation")
    }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("[APNs] FAILED to register: \(error)")
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    print("[APNs] Received remote notification: \(userInfo)")

    Task {
      print("[Inbox] Push received via didReceiveRemoteNotification. Asking inbox UI to refresh.")

      await MainActor.run {
        NotificationCenter.default.post(
          name: self.inboxShouldRefreshNotificationName,
          object: nil
        )
      }

      completionHandler(.newData)
    }
  }

  private func initializeReporting() {
    analyticsController.initialize()
  }

  private func registerSvgCoderToSdImage() {
    SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
  }

  private func initializeWorkers() {
    Task { await revocationWorkManager.start() }
    Task { await reIssuanceWorkManager.start() }
  }
}

// MARK: - User notification handling

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    print("[APNs] Notification received while app is foregrounded: \(notification.request.content.userInfo)")

    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    print("[APNs] User opened notification: \(response.notification.request.content.userInfo)")

    NotificationCenter.default.post(
      name: Notification.Name("inboxShouldRefresh"),
      object: nil
    )

    completionHandler()
  }
}
