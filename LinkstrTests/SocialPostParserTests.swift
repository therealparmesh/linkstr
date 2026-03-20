import XCTest

@testable import Linkstr

final class SocialPostParserTests: XCTestCase {

  // MARK: - Instagram preview from HTML

  func testInstagramPreviewExtractsBodyTextFromOGDescription() {
    let html = """
      <html><head>
      <meta property="og:description" content="120K likes, 528 comments - pg_agi_ on March 9, 2026: &quot;Claude&#039;s recent advancements are giving GPT a run for its money in the quest to develop the most advanced AI model.&quot;. " />
      <meta name="twitter:title" content="Playing God with AGI (&#064;pg_agi_) &#x2022; Instagram reel" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertEqual(
      preview?.bodyText,
      "Claude's recent advancements are giving GPT a run for its money in the quest to develop the most advanced AI model."
    )
    XCTAssertEqual(preview?.authorName, "Playing God with AGI (@pg_agi_)")
  }

  func testInstagramPreviewFallsBackToOGTitleWhenDescriptionMissing() {
    let html = """
      <html><head>
      <meta property="og:title" content="SomeCreator on Instagram: &quot;Check out this cool thing I made&quot;" />
      <meta name="twitter:title" content="SomeCreator &#x2022; Instagram reel" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.bodyText, "Check out this cool thing I made")
    XCTAssertEqual(preview?.authorName, "SomeCreator")
  }

  func testInstagramPreviewExtractsAuthorFromTwitterTitle() {
    let html = """
      <html><head>
      <meta name="twitter:title" content="NASA Artemis (&#064;nasaartemis) &#x2022; Instagram reel" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertNil(preview?.bodyText)
    XCTAssertEqual(preview?.authorName, "NASA Artemis (@nasaartemis)")
  }

  func testInstagramPreviewStripsVariousInstagramSuffixes() {
    let suffixes = [
      " • Instagram reel",
      " • Instagram photo",
      " • Instagram video",
      " • Instagram",
      " \u{2022} Instagram reel",
      " \u{2022} Instagram photo",
      " \u{2022} Instagram video",
      " \u{2022} Instagram",
    ]

    for suffix in suffixes {
      let html = """
        <html><head>
        <meta name="twitter:title" content="TestUser\(suffix)" />
        </head></html>
        """

      let preview = SocialPostHTMLParser.instagramPreview(from: html)
      XCTAssertEqual(preview?.authorName, "TestUser", "Failed to strip suffix: \(suffix)")
    }
  }

  func testInstagramPreviewReturnsNilForEmptyHTML() {
    let preview = SocialPostHTMLParser.instagramPreview(from: "")
    XCTAssertNil(preview)
  }

  func testInstagramPreviewReturnsNilForHTMLWithNoRelevantMeta() {
    let html = """
      <html><head>
      <meta property="og:type" content="article" />
      <meta property="og:site_name" content="Instagram" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)
    XCTAssertNil(preview)
  }

  func testInstagramPreviewDecodesHTMLEntities() {
    let html = """
      <html><head>
      <meta property="og:description" content="5K likes, 10 comments - user on Jan 1, 2026: &quot;Tom &amp; Jerry &lt;3 it&#039;s great&quot;. " />
      <meta name="twitter:title" content="Tom &amp; Jerry &#x2022; Instagram reel" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertEqual(preview?.bodyText, "Tom & Jerry <3 it's great")
    XCTAssertEqual(preview?.authorName, "Tom & Jerry")
  }

  func testInstagramPreviewHandlesDescriptionWithNoCaption() {
    // Some posts have no caption — the og:description is just stats
    let html = """
      <html><head>
      <meta property="og:description" content="50 likes, 2 comments - someuser on April 5, 2026" />
      <meta name="twitter:title" content="someuser &#x2022; Instagram reel" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertNotNil(preview)
    // Body text falls back to the raw description since there's no quote-colon pattern
    XCTAssertEqual(preview?.bodyText, "50 likes, 2 comments - someuser on April 5, 2026")
    XCTAssertEqual(preview?.authorName, "someuser")
  }

  func testInstagramPreviewHandlesMultilineCaption() {
    let html = """
      <html><head>
      <meta property="og:description" content="1K likes, 5 comments - creator on Feb 14, 2026: &quot;Line one. Line two. Line three.&quot;. " />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertEqual(preview?.bodyText, "Line one. Line two. Line three.")
  }

  // MARK: - TikTok preview from JSON

  func testTikTokPreviewExtractsTitleAndAuthor() {
    let json: [String: Any] = [
      "version": "1.0",
      "type": "video",
      "title": "#normmacdonald #normmacdonaldlive #comedy #fyp #jokes ",
      "author_name": "Norm Macdonald",
      "author_url": "https://www.tiktok.com/@norm.macdonald_",
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)

    XCTAssertNotNil(preview)
    XCTAssertEqual(
      preview?.bodyText, "#normmacdonald #normmacdonaldlive #comedy #fyp #jokes")
    XCTAssertEqual(preview?.authorName, "Norm Macdonald")
  }

  func testTikTokPreviewHandlesMissingTitle() {
    let json: [String: Any] = [
      "author_name": "SomeCreator"
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)

    XCTAssertNotNil(preview)
    XCTAssertNil(preview?.bodyText)
    XCTAssertEqual(preview?.authorName, "SomeCreator")
  }

  func testTikTokPreviewHandlesMissingAuthor() {
    let json: [String: Any] = [
      "title": "a cool video"
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)

    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.bodyText, "a cool video")
    XCTAssertNil(preview?.authorName)
  }

  func testTikTokPreviewReturnsNilForEmptyJSON() {
    let preview = SocialPostHTMLParser.tikTokPreview(from: [:])
    XCTAssertNil(preview)
  }

  func testTikTokPreviewTrimsWhitespace() {
    let json: [String: Any] = [
      "title": "  some title  \n",
      "author_name": "  Author  ",
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)

    XCTAssertEqual(preview?.bodyText, "some title")
    XCTAssertEqual(preview?.authorName, "Author")
  }

  func testTikTokPreviewIgnoresEmptyStrings() {
    let json: [String: Any] = [
      "title": "",
      "author_name": "   ",
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)
    XCTAssertNil(preview)
  }

  func testTikTokPreviewIgnoresNonStringValues() {
    let json: [String: Any] = [
      "title": 12345,
      "author_name": true,
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)
    XCTAssertNil(preview)
  }

  // MARK: - Instagram OG description prefix stripping edge cases

  func testInstagramPreviewExtractsBodyWithSmartQuotes() {
    // Some locales use smart quotes in the og:description
    let html = """
      <html><head>
      <meta property="og:description" content="1K likes, 3 comments - user on Jan 1, 2026:\u{00a0}\u{201c}Hello world\u{201d}. " />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)
    XCTAssertEqual(preview?.bodyText, "Hello world")
  }

  func testInstagramPreviewExtractsBodyFromTitleCaseInsensitively() {
    let html = """
      <html><head>
      <meta property="og:title" content="Creator ON INSTAGRAM: &quot;hello&quot;" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)
    XCTAssertEqual(preview?.bodyText, "hello")
  }

}
