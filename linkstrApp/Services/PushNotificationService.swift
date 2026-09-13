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
final class PushNotificationService: NSObject, ObservableObject {
  static let shared = PushNotificationService()

  private(set) var deviceTokenHex: String?

  // Keep the latest tap until the app's root view is ready, including cold launch.
  @Published private(set) var pendingNavigation: SessionNavigationRequest?

  func enqueueNavigation(userInfo: [AnyHashable: Any]) {
    guard let request = SessionNavigationRequest(notification: userInfo) else { return }
    pendingNavigation = request
  }

  func clearPendingNavigation(id: UUID) {
    guard pendingNavigation?.id == id else { return }
    pendingNavigation = nil
  }

  func clearDeliveredNotifications(sessionID: String, postID: String) async {
    let center = UNUserNotificationCenter.current()
    let notifications = await center.deliveredNotifications()
    guard !Task.isCancelled else { return }
    let identifiers = notifications.filter {
      Self.referencesPost($0.request.content.userInfo, sessionID: sessionID, postID: postID)
    }.map { $0.request.identifier }
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }

  static func referencesPost(_ userInfo: [AnyHashable: Any], sessionID: String, postID: String) -> Bool {
    guard !sessionID.isEmpty, !postID.isEmpty,
      (userInfo["conversation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
    else { return false }
    let field: String
    switch userInfo["type"] as? String {
    case "new_post": field = "event_id"
    case "new_emoji_reaction": field = "post_id"
    default: return false
    }
    return (userInfo[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == postID
  }

  override init() {
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
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
      completionHandler()
      return
    }
    Task { @MainActor in
      PushNotificationService.shared.enqueueNavigation(userInfo: userInfo)
      completionHandler()
    }
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
