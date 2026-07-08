import XCTest

@testable import linkstr

extension SocialPostParserTests {

  // MARK: - Facebook preview from HTML

  func testFacebookPreviewExtractsBodyTextFromOGDescription() {
    let html = """
      <html><head>
      <meta property="og:description" \
      content="DM me for parts and you can jump on the remix &#x1f3c6;&#x1f970;" />
      <meta property="og:title" \
      content="DM me for parts and you can jump on the remix &#x1f3c6;&#x1f970; | Example | Facebook" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertEqual(
      preview?.bodyText,
      "DM me for parts and you can jump on the remix \u{1f3c6}\u{1f970}"
    )
  }

  func testFacebookPreviewExtractsAuthorFromOGTitle() {
    let html = """
      <html><head>
      <meta property="og:title" content="Some caption | John Smith | Facebook" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.authorName, "John Smith")
  }

  func testFacebookPreviewParsesSingleQuotedMetaAttributes() {
    let html = """
      <html><head>
      <meta content='Single quoted text' property='og:description' />
      <meta content='Single quoted title | Jane Smith | Facebook' property='og:title' />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)

    XCTAssertEqual(preview?.bodyText, "Single quoted text")
    XCTAssertEqual(preview?.authorName, "Jane Smith")
  }

  func testFacebookPreviewExtractsImageURL() {
    let html = """
      <html><head>
      <meta property="og:image" \
      content="https://scontent.xx.fbcdn.net/v/t51.82787-15/photo.jpg?_nc_cat=111&amp;ccb=1-7" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertNotNil(preview?.imageURL)
    XCTAssertTrue(preview?.imageURL?.absoluteString.contains("scontent") == true)
  }

  func testFacebookPreviewReturnsNilForEmptyHTML() {
    let preview = SocialPostHTMLParser.facebookPreview(from: "")
    XCTAssertNil(preview)
  }

  func testFacebookPreviewReturnsNilForHTMLWithNoRelevantMeta() {
    let html = """
      <html><head>
      <meta property="og:type" content="website" />
      <meta property="og:site_name" content="Facebook" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)
    XCTAssertNil(preview)
  }

  func testFacebookPreviewAuthorNilWhenTitleHasTooFewParts() {
    let html = """
      <html><head>
      <meta property="og:title" content="Just a title | Facebook" />
      <meta property="og:description" content="some text" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.bodyText, "some text")
    XCTAssertNil(preview?.authorName)
  }

  func testFacebookPreviewDecodesHTMLEntities() {
    let html = """
      <html><head>
      <meta property="og:description" content="Tom &amp; Jerry &lt;3 it&#039;s great" />
      <meta property="og:title" content="Tom &amp; Jerry &lt;3 it&#039;s great | Tom &amp; Jerry | Facebook" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)

    XCTAssertEqual(preview?.bodyText, "Tom & Jerry <3 it's great")
    XCTAssertEqual(preview?.authorName, "Tom & Jerry")
  }

  func testFacebookPreviewHandlesDescriptionOnly() {
    let html = """
      <html><head>
      <meta property="og:description" content="A cool video about cats" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.facebookPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.bodyText, "A cool video about cats")
    XCTAssertNil(preview?.authorName)
    XCTAssertNil(preview?.imageURL)
  }
}
