import XCTest

@testable import Linkstr

final class DeepLinkCodecTests: XCTestCase {
  func testAppDeepLinkRoundtrip() throws {
    let payload = LinkstrDeepLinkPayload(
      url: "https://www.tiktok.com/@acct/video/7596114833477537054",
      timestamp: 1_739_877_200,
      messageGUID: UUID().uuidString
    )

    let deepLink = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(payload: payload))
    let parsed = try XCTUnwrap(LinkstrDeepLinkCodec.parsePayload(fromAppDeepLink: deepLink))
    XCTAssertEqual(parsed, payload)
  }

  func testAppDeepLinkRejectsUnexpectedSchemeOrHost() throws {
    let validPayload = LinkstrDeepLinkPayload(
      url: "https://x.com/jack/status/20",
      timestamp: 1_739_877_400,
      messageGUID: UUID().uuidString
    )
    let url = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(payload: validPayload))
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""

    let wrongScheme = URL(string: "https://open?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parsePayload(fromAppDeepLink: wrongScheme))

    let wrongHost = URL(string: "linkstr://watch?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parsePayload(fromAppDeepLink: wrongHost))

    let wrongPath = URL(string: "linkstr://open/deep?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parsePayload(fromAppDeepLink: wrongPath))
  }

  func testAppDeepLinkRejectsNonWebPayloadURL() throws {
    let payload = LinkstrDeepLinkPayload(
      url: "javascript:alert('xss')",
      timestamp: 1_739_877_800,
      messageGUID: UUID().uuidString
    )
    let deepLink = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(payload: payload))
    XCTAssertNil(LinkstrDeepLinkCodec.parsePayload(fromAppDeepLink: deepLink))
  }
}

@MainActor
final class DeepLinkHandlerTests: XCTestCase {
  func testHandleValidDeepLinkSetsPendingPayload() throws {
    let handler = DeepLinkHandler()
    let payload = LinkstrDeepLinkPayload(
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      timestamp: 1_739_877_500,
      messageGUID: "deep-link-guid"
    )
    let url = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(payload: payload))

    XCTAssertTrue(handler.handle(url: url))
    XCTAssertEqual(handler.pendingPayload, payload)
  }

  func testHandleInvalidDeepLinkReturnsFalse() {
    let handler = DeepLinkHandler()
    let invalidURL = URL(string: "linkstr://open?p=not-valid")!

    XCTAssertFalse(handler.handle(url: invalidURL))
    XCTAssertNil(handler.pendingPayload)
  }

  func testClearRemovesPendingPayload() throws {
    let handler = DeepLinkHandler()
    let payload = LinkstrDeepLinkPayload(
      url: "https://www.instagram.com/reel/DUSWiOIDivu/",
      timestamp: 1_739_877_600,
      messageGUID: "clear-guid"
    )
    let url = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(payload: payload))
    XCTAssertTrue(handler.handle(url: url))

    handler.clear()
    XCTAssertNil(handler.pendingPayload)
  }
}
