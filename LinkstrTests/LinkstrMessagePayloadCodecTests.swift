import XCTest

@testable import Linkstr

final class LinkstrMessagePayloadCodecTests: XCTestCase {
  func testEncodeDecodeRoundtrip() throws {
    let payload = LinkstrDeepLinkPayload(
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      timestamp: 1_739_877_001,
      messageGUID: "guid-123"
    )

    let encoded = try XCTUnwrap(LinkstrMessagePayloadCodec.encode(payload))
    let decoded = try XCTUnwrap(LinkstrMessagePayloadCodec.decode(encoded))
    XCTAssertEqual(decoded, payload)
  }

  func testMessageURLRoundtrip() throws {
    let payload = LinkstrDeepLinkPayload(
      url: "https://www.instagram.com/reel/DUSWiOIDivu/",
      timestamp: 1_739_877_100,
      messageGUID: UUID().uuidString
    )

    let messageURL = try XCTUnwrap(LinkstrMessagePayloadCodec.makeMessageURL(payload: payload))
    let parsed = try XCTUnwrap(LinkstrMessagePayloadCodec.parsePayload(fromMessageURL: messageURL))
    XCTAssertEqual(parsed, payload)
  }

  func testAppDeepLinkRoundtrip() throws {
    let payload = LinkstrDeepLinkPayload(
      url: "https://www.tiktok.com/@acct/video/7596114833477537054",
      timestamp: 1_739_877_200,
      messageGUID: UUID().uuidString
    )

    let deepLink = try XCTUnwrap(LinkstrMessagePayloadCodec.makeAppDeepLink(payload: payload))
    let parsed = try XCTUnwrap(LinkstrMessagePayloadCodec.parsePayload(fromAppDeepLink: deepLink))
    XCTAssertEqual(parsed, payload)
  }

  func testMessageURLRejectsUnexpectedHostOrPath() throws {
    let validPayload = LinkstrDeepLinkPayload(
      url: "https://rumble.com/v8tc4h9-clip.html",
      timestamp: 1_739_877_300,
      messageGUID: UUID().uuidString
    )
    let token = try XCTUnwrap(LinkstrMessagePayloadCodec.encode(validPayload))

    let wrongHost = URL(string: "https://example.com/messages/open?p=\(token)")!
    XCTAssertNil(LinkstrMessagePayloadCodec.parsePayload(fromMessageURL: wrongHost))

    let wrongPath = URL(string: "https://linkstr.app/open?p=\(token)")!
    XCTAssertNil(LinkstrMessagePayloadCodec.parsePayload(fromMessageURL: wrongPath))

    let wrongScheme = URL(string: "http://linkstr.app/messages/open?p=\(token)")!
    XCTAssertNil(LinkstrMessagePayloadCodec.parsePayload(fromMessageURL: wrongScheme))
  }

  func testAppDeepLinkRejectsUnexpectedSchemeOrHost() throws {
    let validPayload = LinkstrDeepLinkPayload(
      url: "https://x.com/jack/status/20",
      timestamp: 1_739_877_400,
      messageGUID: UUID().uuidString
    )
    let token = try XCTUnwrap(LinkstrMessagePayloadCodec.encode(validPayload))

    let wrongScheme = URL(string: "https://open?p=\(token)")!
    XCTAssertNil(LinkstrMessagePayloadCodec.parsePayload(fromAppDeepLink: wrongScheme))

    let wrongHost = URL(string: "linkstr://watch?p=\(token)")!
    XCTAssertNil(LinkstrMessagePayloadCodec.parsePayload(fromAppDeepLink: wrongHost))

    let wrongPath = URL(string: "linkstr://open/deep?p=\(token)")!
    XCTAssertNil(LinkstrMessagePayloadCodec.parsePayload(fromAppDeepLink: wrongPath))
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
    let url = try XCTUnwrap(LinkstrMessagePayloadCodec.makeAppDeepLink(payload: payload))

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
    let url = try XCTUnwrap(LinkstrMessagePayloadCodec.makeAppDeepLink(payload: payload))
    XCTAssertTrue(handler.handle(url: url))

    handler.clear()
    XCTAssertNil(handler.pendingPayload)
  }
}
