import XCTest

@testable import linkstr

final class DeepLinkCodecTests: XCTestCase {
  func testAppDeepLinkRoundtrip() throws {
    let urlString = "https://www.tiktok.com/@acct/video/7596114833477537054"

    let deepLink = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(url: urlString))
    let parsed = try XCTUnwrap(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: deepLink))
    XCTAssertEqual(parsed, urlString)
  }

  func testShareDeepLinkRoundtripWithOptionalNote() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "example.com/watch",
        note: "  worth saving & tagging? yes  "
      )
    )

    let draft = try XCTUnwrap(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.url, "https://example.com/watch")
    XCTAssertEqual(draft.note, "worth saving & tagging? yes")
  }

  func testShareDeepLinkOmitsBlankNote() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "https://example.com/watch",
        note: " \n\t "
      )
    )

    let draft = try XCTUnwrap(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.url, "https://example.com/watch")
    XCTAssertNil(draft.note)
  }

  func testShareDeepLinkLimitsNoteLength() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "https://example.com/watch",
        note: String(repeating: "a", count: 4_005)
      )
    )

    let draft = try XCTUnwrap(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.note?.count, 4_000)
  }

  func testMediaSaveDeepLinkRoundtrip() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "example.com/video.mp4"))

    let draft = try XCTUnwrap(
      LinkstrDeepLinkCodec.parseMediaSaveDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.url, "https://example.com/video.mp4")
  }

  func testRouteParsingDistinguishesOpenShareAndMediaSave() throws {
    let openDeepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeAppDeepLink(url: "https://example.com/open"))
    let shareDeepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "https://example.com/share"))
    let mediaSaveDeepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "https://example.com/video.mp4"))

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: openDeepLink),
      .openURL("https://example.com/open")
    )
    XCTAssertNil(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: openDeepLink))
    XCTAssertNil(LinkstrDeepLinkCodec.parseMediaSaveDraft(fromAppDeepLink: openDeepLink))

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: shareDeepLink),
      .share(LinkstrDeepLinkCodec.ShareDraft(url: "https://example.com/share", note: nil))
    )
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: shareDeepLink))
    XCTAssertNil(LinkstrDeepLinkCodec.parseMediaSaveDraft(fromAppDeepLink: shareDeepLink))

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: mediaSaveDeepLink),
      .mediaSave(
        LinkstrDeepLinkCodec.MediaSaveDraft(url: "https://example.com/video.mp4"))
    )
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: mediaSaveDeepLink))
    XCTAssertNil(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: mediaSaveDeepLink))
  }

  func testAppDeepLinkRejectsUnexpectedSchemeOrHost() throws {
    let url = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeAppDeepLink(url: "https://x.com/jack/status/20"))
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""

    let wrongScheme = URL(string: "https://open?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongScheme))

    let wrongHost = URL(string: "linkstr://watch?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongHost))
    XCTAssertNil(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: wrongHost))

    let wrongPath = URL(string: "linkstr://open/deep?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongPath))
    XCTAssertNil(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: wrongPath))
  }

  func testAppDeepLinkRejectsNonWebPayloadURL() throws {
    XCTAssertNil(LinkstrDeepLinkCodec.makeAppDeepLink(url: "javascript:alert('xss')"))
    XCTAssertNil(LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "javascript:alert('xss')"))
    XCTAssertNil(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "javascript:alert('xss')"))
  }

  func testShareDeepLinkRejectsMissingPayloadURL() {
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: URL(string: "linkstr://share")!)
    )
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: URL(string: "linkstr://share?note=hi")!)
    )
  }

  func testMediaSaveDeepLinkRejectsMissingPayloadURL() {
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseMediaSaveDraft(
        fromAppDeepLink: URL(string: "linkstr://save")!)
    )
  }

  func testAppDeepLinkRejectsRemovedPayloadFormat() {
    let legacyURL = URL(
      string:
        "linkstr://open?p=eyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tL3ZpZGVvIiwidGltZXN0YW1wIjoxLCJtZXNzYWdlR1VJRCI6ImFiYyJ9"
    )!

    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: legacyURL))
  }
}
