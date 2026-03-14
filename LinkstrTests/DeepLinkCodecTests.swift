import XCTest

@testable import Linkstr

final class DeepLinkCodecTests: XCTestCase {
  func testAppDeepLinkRoundtrip() throws {
    let urlString = "https://www.tiktok.com/@acct/video/7596114833477537054"

    let deepLink = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(url: urlString))
    let parsed = try XCTUnwrap(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: deepLink))
    XCTAssertEqual(parsed, urlString)
  }

  func testAppDeepLinkRejectsUnexpectedSchemeOrHost() throws {
    let url = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeAppDeepLink(url: "https://x.com/jack/status/20"))
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""

    let wrongScheme = URL(string: "https://open?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongScheme))

    let wrongHost = URL(string: "linkstr://watch?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongHost))

    let wrongPath = URL(string: "linkstr://open/deep?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongPath))
  }

  func testAppDeepLinkRejectsNonWebPayloadURL() throws {
    XCTAssertNil(LinkstrDeepLinkCodec.makeAppDeepLink(url: "javascript:alert('xss')"))
  }

  func testAppDeepLinkBuilderUsesValidatedURL() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeAppDeepLink(url: "https://example.com/video"))

    let parsed = try XCTUnwrap(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: deepLink))
    XCTAssertEqual(parsed, "https://example.com/video")
  }

  func testAppDeepLinkRejectsRemovedPayloadFormat() {
    let legacyURL = URL(
      string:
        "linkstr://open?p=eyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tL3ZpZGVvIiwidGltZXN0YW1wIjoxLCJtZXNzYWdlR1VJRCI6ImFiYyJ9"
    )!

    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: legacyURL))
  }
}
