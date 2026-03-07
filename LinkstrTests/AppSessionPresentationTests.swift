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
    let html = TwitterEmbedDocumentBuilder.documentHTML(tweetID: "20")

    XCTAssertTrue(html.contains("body.linkstr-embed-ready"))
    XCTAssertTrue(html.contains("opacity: 0"))
    XCTAssertTrue(html.contains("linkstrEmbedMetrics"))
    XCTAssertTrue(html.contains("MutationObserver"))
    XCTAssertTrue(html.contains("ResizeObserver"))
    XCTAssertTrue(html.contains("createTweet(tweetID, container"))
    XCTAssertTrue(html.contains("tweet-container"))
    XCTAssertTrue(html.contains("platform.twitter.com/widgets.js"))
  }

  func testTwitterStatusResponseParserExtractsPreviewFromVXPath() throws {
    let json = try jsonObject(
      from: """
        {
          "user_name": "frankie",
          "user_screen_name": "FrankieIsLost",
          "mediaURLs": ["https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg"],
          "media_extended": [
            {
              "type": "image",
              "thumbnail_url": "https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg",
              "url": "https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg"
            }
          ]
        }
        """
    )

    let summary = TwitterStatusResponseParser.mediaSummary(from: json)
    XCTAssertFalse(summary.hasVideo)
    XCTAssertEqual(summary.preview?.title, "frankie (@FrankieIsLost)")
    XCTAssertEqual(
      summary.preview?.imageURL?.absoluteString,
      "https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg"
    )
  }

  func testTwitterStatusResponseParserExtractsPreviewFromFXPath() throws {
    let json = try jsonObject(
      from: """
        {
          "tweet": {
            "author": {
              "name": "AlphaFox",
              "screen_name": "alphafox"
            },
            "media": {
              "photos": [
                {
                  "type": "photo",
                  "url": "https://pbs.twimg.com/media/example-photo.jpg?name=orig",
                  "width": 951,
                  "height": 419
                }
              ]
            }
          }
        }
        """
    )

    let summary = TwitterStatusResponseParser.mediaSummary(from: json)
    XCTAssertFalse(summary.hasVideo)
    XCTAssertEqual(summary.preview?.title, "AlphaFox (@alphafox)")
    XCTAssertEqual(
      summary.preview?.imageURL?.absoluteString,
      "https://pbs.twimg.com/media/example-photo.jpg?name=orig"
    )
  }

  func testLinkMetadataRefreshPolicyRefreshesWhenTitleIsMissing() {
    XCTAssertTrue(
      LinkMetadataRefreshPolicy.needsRefresh(
        linkType: .generic,
        title: "   ",
        thumbnailPath: "/tmp/thumb.png",
        fileExists: { _ in true }
      )
    )
  }

  func testLinkMetadataRefreshPolicyRefreshesTwitterWhenThumbnailIsMissing() {
    XCTAssertTrue(
      LinkMetadataRefreshPolicy.needsRefresh(
        linkType: .twitter,
        title: "frankie (@FrankieIsLost)",
        thumbnailPath: nil
      )
    )
  }

  func testLinkMetadataRefreshPolicyDoesNotRefreshGenericWhenThumbnailIsMissing() {
    XCTAssertFalse(
      LinkMetadataRefreshPolicy.needsRefresh(
        linkType: .generic,
        title: "Example title",
        thumbnailPath: nil
      )
    )
  }

  func testLinkMetadataRefreshPolicyRefreshesWhenStoredThumbnailFileIsMissing() {
    XCTAssertTrue(
      LinkMetadataRefreshPolicy.needsRefresh(
        linkType: .generic,
        title: "Example title",
        thumbnailPath: "/tmp/thumb.png",
        fileExists: { _ in false }
      )
    )
  }

  func testLinkMetadataRefreshPolicySkipsRefreshWhenTitleAndThumbnailArePresent() {
    XCTAssertFalse(
      LinkMetadataRefreshPolicy.needsRefresh(
        linkType: .twitter,
        title: "AlphaFox (@alphafox)",
        thumbnailPath: "/tmp/thumb.png",
        fileExists: { _ in true }
      )
    )
  }

  private func jsonObject(from raw: String) throws -> [String: Any] {
    let data = try XCTUnwrap(raw.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
