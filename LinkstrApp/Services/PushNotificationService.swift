import Combine
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

  /// Conversation ID from a tapped push notification, stored so it survives
  /// cold-launch timing where SwiftUI subscribers aren't yet registered.
  @Published private(set) var pendingConversationID: String?

  func enqueueConversationNavigation(to rawConversationID: String?) {
    guard let rawConversationID else { return }
    let conversationID = rawConversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !conversationID.isEmpty else { return }
    pendingConversationID = conversationID
  }

  /// Reads and clears the pending conversation ID in a single call.
  func consumePendingConversationID() -> String? {
    guard let id = pendingConversationID else { return nil }
    pendingConversationID = nil
    return id
  }

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

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if let conversationID = userInfo["conversation_id"] as? String {
      Task { @MainActor in
        PushNotificationService.shared.enqueueConversationNavigation(to: conversationID)
        completionHandler()
      }
      return
    }
    completionHandler()
  }
}

final class LinkstrAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    PushNotificationService.shared.configure()
    return true
  }

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
