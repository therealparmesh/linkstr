import XCTest

@testable import linkstr

final class SocialPostParserTests: XCTestCase {

  // MARK: - Instagram preview from HTML

  func testInstagramPreviewExtractsBodyTextFromOGDescription() {
    let html = """
      <html><head>
      <meta property="og:description" content="120K likes, 528 comments - pg_agi_ on March 9, 2026: \
      &quot;Claude&#039;s recent advancements are giving GPT a run for its money \
      in the quest to develop the most advanced AI model.&quot;. " />
      <meta name="twitter:title" content="Playing God with AGI (&#064;pg_agi_) &#x2022; Instagram reel" />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertNotNil(preview)
    XCTAssertEqual(
      preview?.bodyText,
      "Claude's recent advancements are giving GPT a run for its money "
        + "in the quest to develop the most advanced AI model."
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
      " \u{2022} Instagram"
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

  func testInstagramMediaKindDetectsOpenGraphVideo() {
    let html = """
      <html><head>
      <meta property="og:type" content="video" />
      <meta name="medium" content="video" />
      <meta property="og:video:secure_url" content="https://cdn.example.com/video.mp4?token=one&amp;expires=soon" />
      <meta name="twitter:title" content="Creator &#x2022; Instagram video" />
      </head></html>
      """

    XCTAssertEqual(SocialPostHTMLParser.instagramMediaKind(from: html), .video)
    XCTAssertEqual(
      SocialVideoExtractionService.extractOGVideoURLs(fromHTML: html).first?.absoluteString,
      "https://cdn.example.com/video.mp4?token=one&expires=soon"
    )
  }

  func testInstagramMediaKindDetectsPhotoPost() {
    let html = """
      <html><head>
      <meta property="og:type" content="instapp:photo" />
      <meta name="medium" content="image" />
      <meta name="twitter:title" content="Creator &#x2022; Instagram photo" />
      <meta property="og:image" content="https://cdn.example.com/photo.jpg" />
      </head></html>
      """

    XCTAssertEqual(SocialPostHTMLParser.instagramMediaKind(from: html), .nonVideo)
    XCTAssertTrue(SocialVideoExtractionService.extractOGVideoURLs(fromHTML: html).isEmpty)
  }

  func testInstagramMediaKindIsUnknownWithoutMediaSignals() {
    let html = """
      <html><head>
      <meta property="og:site_name" content="Instagram" />
      </head></html>
      """

    XCTAssertEqual(SocialPostHTMLParser.instagramMediaKind(from: html), .unknown)
  }

  func testInstagramPreviewDecodesHTMLEntities() {
    let html = """
      <html><head>
      <meta property="og:description" content="5K likes, 10 comments - user on Jan 1, 2026: \
      &quot;Tom &amp; Jerry &lt;3 it&#039;s great&quot;. " />
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
      <meta property="og:description" content="1K likes, 5 comments - creator on Feb 14, 2026: \
      &quot;Line one. Line two. Line three.&quot;. " />
      </head></html>
      """

    let preview = SocialPostHTMLParser.instagramPreview(from: html)

    XCTAssertEqual(preview?.bodyText, "Line one. Line two. Line three.")
  }

  func testLikelyMediaURLRecognizesSignedInstagramCDNVideoWithoutMP4Suffix() {
    let url =
      "https://scontent-dfw5-2.cdninstagram.com/o1/v/t16/f2/m86/"
      + "8A4D5A0D62B8E6B4D3F1E9D3C7A4B8C?stp=dst-jpg_e15_fr_qp1080x1080"
      + "&_nc_ht=scontent-dfw5-2.cdninstagram.com&oe=67FA0D8F&oh=00_AYBexample"

    XCTAssertTrue(SocialVideoExtractionService.isLikelyMediaURLString(url.lowercased()))
  }

  func testLikelyMediaURLRecognizesSignedFBCDNInstagramVideoWithoutMP4Suffix() {
    let url =
      "https://scontent-lax3-2.xx.fbcdn.net/o1/v/t16/f2/m86/"
      + "2D6C9F7A8B4E1D3C5A7B9E2F4D6C8A0?stp=dst-jpg_e15_fr_qp1080x1080"
      + "&efg=eyJ2ZW5jb2RlX3RhZyI6InYxX3YxMCJ9"
      + "&_nc_ht=scontent-lax3-2.xx.fbcdn.net&oe=67FA0D8F&oh=00_AYBexample"

    XCTAssertTrue(SocialVideoExtractionService.isLikelyMediaURLString(url.lowercased()))
  }

  func testLikelyMediaURLRejectsInstagramCDNImageURL() {
    let url =
      "https://scontent-dfw5-2.cdninstagram.com/v/t51.82787-15/"
      + "611216339_17928777444190749_4481488707119326601_n.jpg"
      + "?stp=cmp1_dst-jpg_e35_s640x640_tt6&_nc_cat=108&ccb=7-5"
      + "&_nc_sid=18de74&_nc_ht=scontent-dfw5-2.cdninstagram.com&oe=69D1EEB6"

    XCTAssertFalse(SocialVideoExtractionService.isLikelyMediaURLString(url.lowercased()))
  }
}
