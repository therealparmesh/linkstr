import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import linkstr

@MainActor
final class NotificationNavigationTests: AppSessionTestCase {
  func testDeliveredAlertMatchingUsesPostTargetsAndLeavesUnrelatedAlertsAlone() {
    let payloads: [([AnyHashable: Any], Bool)] = [
      (["conversation_id": "session", "type": "new_post", "event_id": "post"], true),
      (
        [
          "conversation_id": "session", "type": "new_emoji_reaction", "post_id": "post",
          "event_id": "reaction"
        ], true
      ),
      (["conversation_id": "other", "type": "new_post", "event_id": "post"], false),
      (["conversation_id": "session", "type": "new_post", "event_id": "other"], false),
      (["conversation_id": "session", "type": "new_emoji_reaction", "event_id": "post"], false),
      (["conversation_id": "session", "type": "unknown", "post_id": "post"], false),
      (["conversation_id": "session", "type": "new_post", "event_id": 42], false)
    ]
    for (payload, expected) in payloads {
      XCTAssertEqual(
        PushNotificationService.referencesPost(payload, sessionID: "session", postID: "post"),
        expected)
    }
  }

  func testNotificationDestinationsValidateIDsAndPreserveLegacyFallback() {
    let cases: [([AnyHashable: Any], [SessionRoute]?)] = [
      ([:], nil),
      (["conversation_id": 42], nil),
      (["conversation_id": " \n"], nil),
      (["conversation_id": " session "], [.session("session")]),
      (["conversation_id": "session", "type": "new_post", "post_id": "ignored"],
       [.session("session")]),
      (["conversation_id": "session", "type": "new_emoji_reaction", "event_id": "reaction"],
       [.session("session")]),
      (["conversation_id": "session", "type": "new_emoji_reaction", "post_id": " "],
       [.session("session")]),
      (["conversation_id": "session", "type": "new_emoji_reaction", "post_id": " post ",
        "event_id": "reaction"], [.session("session", scrollToPostID: "post")])
    ]
    for (payload, expected) in cases {
      XCTAssertEqual(SessionNavigationRequest(notification: payload)?.path, expected)
    }
  }

  func testLatestTapSurvivesMalformedInputAndStaleAcknowledgement() throws {
    let notifications = PushNotificationService()
    notifications.enqueueNavigation(userInfo: ["conversation_id": "session"])
    let first = try XCTUnwrap(notifications.pendingNavigation)
    notifications.enqueueNavigation(userInfo: ["conversation_id": "session"])
    let second = try XCTUnwrap(notifications.pendingNavigation)
    XCTAssertNotEqual(first.id, second.id)
    notifications.clearPendingNavigation(id: first.id)
    notifications.enqueueNavigation(userInfo: ["conversation_id": " "])
    XCTAssertEqual(notifications.pendingNavigation, second)
    notifications.clearPendingNavigation(id: second.id)
    XCTAssertNil(notifications.pendingNavigation)
  }

  func testColdStartupAndSubsequentTapsReplaceTheVisibleNavigationStack() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    session.refreshIdentityState()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner,
      memberPubkeys: [owner], sessionID: "session"
    )
    let notifications = PushNotificationService()
    let deepLinks = DeepLinkHandler()
    let reaction: [AnyHashable: Any] = [
      "conversation_id": "session", "type": "new_emoji_reaction", "post_id": "post"
    ]
    notifications.enqueueNavigation(userInfo: reaction)

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(
      rootView: RootView(pushNotifications: notifications)
        .environmentObject(session)
        .environmentObject(deepLinks)
        .modelContainer(container)
    )
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKeyAndVisible()
    }

    await waitUntil { session.pendingSessionNavigationRequest?.postID == "post" }
    session.didFinishBoot = true
    await waitUntil { self.navigationController(in: host)?.viewControllers.count == 2 }
    try await verifyLatePostScrollsWithoutOpening(in: container.mainContext, owner: owner, host: host)

    notifications.enqueueNavigation(userInfo: ["conversation_id": "session", "type": "new_post"])
    await waitUntil { self.navigationController(in: host)?.viewControllers.count == 2 }

    notifications.enqueueNavigation(userInfo: reaction)
    await waitUntil { notifications.pendingNavigation == nil }
    let reactionStack = try XCTUnwrap(navigationController(in: host))
    notifications.enqueueNavigation(userInfo: reaction)
    await waitUntil {
      guard let current = self.navigationController(in: host) else { return false }
      return current !== reactionStack && current.viewControllers.count == 2
    }

    notifications.enqueueNavigation(userInfo: reaction)
    notifications.enqueueNavigation(userInfo: ["conversation_id": "other-session"])
    await waitUntil { notifications.pendingNavigation == nil && session.pendingSessionNavigationRequest == nil }
    XCTAssertNil(session.pendingSessionNavigationRequest)
    XCTAssertNil(notifications.pendingNavigation)
  }

  private func verifyLatePostScrollsWithoutOpening(
    in context: ModelContext, owner: String, host: UIViewController
  ) async throws {
    for index in 0..<40 {
      context.insert(try SessionMessageEntity(
        eventID: "filler-\(index)", ownerPubkey: owner, conversationID: "session", rootID: "filler-\(index)",
        kind: .root, senderPubkey: owner, url: nil, note: nil, timestamp: .now, linkType: .generic
      ))
    }
    let post = try SessionMessageEntity(
      eventID: "post", ownerPubkey: owner, conversationID: "session", rootID: "post",
      kind: .root, senderPubkey: String(repeating: "b", count: 64), url: nil, note: nil,
      timestamp: .now.addingTimeInterval(-60), linkType: .generic
    )
    context.insert(post)
    try context.save()
    await waitUntil { self.hasScrolledList(in: host.view) }
    XCTAssertNil(post.readAt, "notification scrolling must not open the post detail")
  }

  private func hasScrolledList(in view: UIView) -> Bool {
    if let scroll = view as? UIScrollView, scroll.contentOffset.y > 500 { return true }
    return view.subviews.contains { self.hasScrolledList(in: $0) }
  }

  private func navigationController(in controller: UIViewController) -> UINavigationController? {
    if let navigation = controller as? UINavigationController { return navigation }
    return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}
