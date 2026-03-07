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
    content.body = Self.incomingPostBody(note: note, fallback: url ?? "open linkstr to view")
    content.sound = .default
    content.threadIdentifier = conversationID

    let request = UNNotificationRequest(
      identifier: "linkstr-post-\(eventID)",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    )
    UNUserNotificationCenter.current().add(request)
  }

  func postIncomingReactionNotification(
    senderName: String,
    emoji: String,
    postPreview: String?,
    eventID: String,
    conversationID: String
  ) {
    let content = UNMutableNotificationContent()
    content.title = "\(senderName) reacted \(emoji)"
    content.body = Self.incomingReactionBody(emoji: emoji, postPreview: postPreview)
    content.sound = .default
    content.threadIdentifier = conversationID

    let request = UNNotificationRequest(
      identifier: "linkstr-reaction-\(eventID)",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    )
    UNUserNotificationCenter.current().add(request)
  }

  static func incomingPostBody(note: String?, fallback: String) -> String {
    let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallback : trimmed
  }

  static func incomingReactionBody(emoji: String, postPreview: String?) -> String {
    let normalizedPreview = postPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !normalizedPreview.isEmpty else {
      return "reacted with \(emoji)"
    }
    return "reacted with \(emoji) to \(normalizedPreview)"
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
