import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

@MainActor
final class AppSessionPresentationTests: AppSessionTestCase {
  func testReactionSummaryBadgeTextCapsAtTenPlus() {
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 1, includesCurrentUser: false).badgeText,
      "1"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 10, includesCurrentUser: false).badgeText,
      "10"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 11, includesCurrentUser: false).badgeText,
      "10+"
    )
  }

  func testReactionSummaryReadOnlyBadgeTextHidesSingleReaction() {
    XCTAssertNil(
      ReactionSummary(emoji: "🔥", count: 1, includesCurrentUser: false).readOnlyBadgeText
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 2, includesCurrentUser: false).readOnlyBadgeText,
      "2"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 12, includesCurrentUser: false).readOnlyBadgeText,
      "10+"
    )
  }

  func testTwitterEmbedDocumentDefersRevealAndPostsMetrics() {
    let html = TwitterEmbedDocumentBuilder.documentHTML(from: "<blockquote>tweet</blockquote>")

    XCTAssertTrue(html.contains("body.linkstr-embed-ready"))
    XCTAssertTrue(html.contains("opacity: 0"))
    XCTAssertTrue(html.contains("linkstrEmbedMetrics"))
    XCTAssertTrue(html.contains("MutationObserver"))
    XCTAssertTrue(html.contains("ResizeObserver"))
  }

  func testIncomingReactionNotificationBodyUsesPreviewWhenAvailable() {
    XCTAssertEqual(
      LocalNotificationService.incomingReactionBody(emoji: "🔥", postPreview: "A very good post"),
      "reacted with 🔥 to A very good post"
    )
    XCTAssertEqual(
      LocalNotificationService.incomingReactionBody(emoji: "🔥", postPreview: nil),
      "reacted with 🔥"
    )
    XCTAssertEqual(
      LocalNotificationService.incomingReactionBody(emoji: "🔥", postPreview: "   "),
      "reacted with 🔥"
    )
  }
}
