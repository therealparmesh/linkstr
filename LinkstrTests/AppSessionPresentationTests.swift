import XCTest

@testable import Linkstr

final class AppSessionPresentationTests: XCTestCase {
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
}
