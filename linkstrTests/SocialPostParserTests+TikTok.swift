import XCTest

@testable import linkstr

extension SocialPostParserTests {

  // MARK: - TikTok preview from JSON

  func testTikTokPreviewExtractsTitleAndAuthor() {
    let json: [String: Any] = [
      "version": "1.0",
      "type": "video",
      "title": "#normmacdonald #normmacdonaldlive #comedy #fyp #jokes ",
      "author_name": "Norm Macdonald",
      "author_url": "https://www.tiktok.com/@norm.macdonald_"
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
      "author_name": "  Author  "
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)

    XCTAssertEqual(preview?.bodyText, "some title")
    XCTAssertEqual(preview?.authorName, "Author")
  }

  func testTikTokPreviewIgnoresEmptyStrings() {
    let json: [String: Any] = [
      "title": "",
      "author_name": "   "
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)
    XCTAssertNil(preview)
  }

  func testTikTokPreviewIgnoresNonStringValues() {
    let json: [String: Any] = [
      "title": 12345,
      "author_name": true
    ]

    let preview = SocialPostHTMLParser.tikTokPreview(from: json)
    XCTAssertNil(preview)
  }

  // MARK: - Instagram OG description prefix stripping edge cases

  func testInstagramPreviewExtractsBodyWithSmartQuotes() {
    // Some locales use smart quotes in the og:description
    let html = """
      <html><head>
      <meta property="og:description" content="1K likes, 3 comments - \
      user on Jan 1, 2026:\u{00a0}\u{201c}Hello world\u{201d}. " />
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
