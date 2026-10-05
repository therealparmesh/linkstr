import Foundation
import UIKit

extension AppSession {
  @discardableResult
  func markSessionRead(sessionID: String, ownerPubkey: String) -> Bool {
    guard identityService.pubkeyHex == ownerPubkey, !isRestoringBackup else { return false }
    let date = Date.now
    do {
      let postIDs = try messageStore.markSessionRead(sessionID: sessionID, ownerPubkey: ownerPubkey, at: date)
      guard !postIDs.isEmpty else { return true }
      UIAccessibility.post(notification: .announcement, argument: "marked all as read")
      let source = nostrService
      Task { [weak self, weak source] in
        await PushNotificationService.shared.clearDeliveredNotifications(
          sessionID: sessionID, postIDs: postIDs, through: date
        ) {
          self?.identityService.pubkeyHex == ownerPubkey && self?.nostrService === source
        }
      }
      return true
    } catch {
      report(error: error)
      return false
    }
  }
}
