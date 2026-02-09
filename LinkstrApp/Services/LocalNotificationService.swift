import Foundation
@preconcurrency import UserNotifications

@MainActor
final class LocalNotificationService: NSObject {
  static let shared = LocalNotificationService()

  private override init() {
    super.init()
  }

  func configure() {
    UNUserNotificationCenter.current().delegate = self
  }

  func requestAuthorizationIfNeeded() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
        _, _ in
      }
    }
  }

  func postIncomingPostNotification(
    senderName: String, url: String?, note: String?, eventID: String, conversationID: String
  ) {
    let content = UNMutableNotificationContent()
    content.title = "\(senderName) shared a post"
    content.body = notificationBody(note: note, fallback: url ?? "Open linkstr to view")
    content.sound = .default
    content.threadIdentifier = conversationID

    let request = UNNotificationRequest(
      identifier: "linkstr-post-\(eventID)",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    )
    UNUserNotificationCenter.current().add(request)
  }

  func postIncomingReplyNotification(
    senderName: String, note: String?, eventID: String, conversationID: String
  ) {
    let content = UNMutableNotificationContent()
    content.title = "\(senderName) replied"
    content.body = notificationBody(note: note, fallback: "Open linkstr to view reply")
    content.sound = .default
    content.threadIdentifier = conversationID

    let request = UNNotificationRequest(
      identifier: "linkstr-reply-\(eventID)",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    )
    UNUserNotificationCenter.current().add(request)
  }

  private func notificationBody(note: String?, fallback: String) -> String {
    let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallback : trimmed
  }
}

extension LocalNotificationService: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }
}
