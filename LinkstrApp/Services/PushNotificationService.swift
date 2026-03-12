import Foundation
import UIKit
@preconcurrency import UserNotifications

extension Notification.Name {
  static let linkstrPushDeviceTokenDidChange = Notification.Name(
    "linkstr.pushDeviceTokenDidChange"
  )
}

@MainActor
final class PushNotificationService: NSObject {
  static let shared = PushNotificationService()

  private(set) var deviceTokenHex: String?

  private override init() {
    super.init()
  }

  var apnsEnvironment: String {
    #if DEBUG
      "sandbox"
    #else
      "production"
    #endif
  }

  func configure() {
    UNUserNotificationCenter.current().delegate = self
  }

  func requestAuthorizationIfNeeded() {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        self.registerForRemoteNotifications()
      case .notDetermined:
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
          guard granted else { return }
          self.registerForRemoteNotifications()
        }
      case .denied:
        break
      @unknown default:
        break
      }
    }
  }

  func refreshRegistrationIfAuthorized() {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        self.registerForRemoteNotifications()
      case .notDetermined, .denied:
        break
      @unknown default:
        break
      }
    }
  }

  func handleRegisteredDeviceToken(_ token: Data) {
    let nextTokenHex = token.map { String(format: "%02x", $0) }.joined()
    guard deviceTokenHex != nextTokenHex else { return }
    deviceTokenHex = nextTokenHex
    NotificationCenter.default.post(name: .linkstrPushDeviceTokenDidChange, object: nil)
  }

  func handleRegistrationFailure(_ error: Error) {
    NSLog("APNs registration failed: \(error.localizedDescription)")
  }

  private nonisolated func registerForRemoteNotifications() {
    Task { @MainActor in
      UIApplication.shared.registerForRemoteNotifications()
    }
  }
}

extension PushNotificationService: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }
}

final class LinkstrAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Task { @MainActor in
      PushNotificationService.shared.handleRegisteredDeviceToken(deviceToken)
    }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Task { @MainActor in
      PushNotificationService.shared.handleRegistrationFailure(error)
    }
  }
}
