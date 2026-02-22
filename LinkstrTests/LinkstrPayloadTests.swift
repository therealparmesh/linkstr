import XCTest

@testable import Linkstr

final class LinkstrPayloadTests: XCTestCase {
  func testRootPayloadValidationRequiresValidURL() {
    let valid = LinkstrPayload(
      conversationID: "c1",
      rootID: "r1",
      kind: .root,
      url: "https://example.com",
      note: "note",
      timestamp: 123
    )
    XCTAssertNoThrow(try valid.validated())

    let invalid = LinkstrPayload(
      conversationID: "c1",
      rootID: "r1",
      kind: .root,
      url: nil,
      note: nil,
      timestamp: 123
    )
    XCTAssertThrowsError(try invalid.validated())

    let invalidScheme = LinkstrPayload(
      conversationID: "c1",
      rootID: "r1",
      kind: .root,
      url: "ftp://example.com/video.mp4",
      note: nil,
      timestamp: 123
    )
    XCTAssertThrowsError(try invalidScheme.validated())
  }

  func testDecodeWithoutTimestampBackfillsNow() throws {
    let json = """
      {
        "conversation_id": "conversation",
        "root_id": "root",
        "kind": "root",
        "url": "https://example.com"
      }
      """
    let before = Int64(Date.now.timeIntervalSince1970) - 1
    let payload = try JSONDecoder().decode(LinkstrPayload.self, from: Data(json.utf8))
    let after = Int64(Date.now.timeIntervalSince1970) + 1

    XCTAssertGreaterThanOrEqual(payload.timestamp, before)
    XCTAssertLessThanOrEqual(payload.timestamp, after)
    XCTAssertEqual(payload.kind, .root)
    XCTAssertEqual(payload.url, "https://example.com")
  }

  func testNormalizedWebURLAcceptsHTTPAndHTTPS() {
    XCTAssertEqual(
      LinkstrURLValidator.normalizedWebURL(from: " https://example.com/path?q=1 "),
      "https://example.com/path?q=1"
    )
    XCTAssertEqual(
      LinkstrURLValidator.normalizedWebURL(from: "http://example.com"),
      "http://example.com"
    )
  }

  func testNormalizedWebURLRejectsUnsupportedOrMalformedValues() {
    XCTAssertNil(LinkstrURLValidator.normalizedWebURL(from: "ftp://example.com/file"))
    XCTAssertNil(LinkstrURLValidator.normalizedWebURL(from: "mailto:test@example.com"))
    XCTAssertNil(LinkstrURLValidator.normalizedWebURL(from: "https://"))
    XCTAssertNil(LinkstrURLValidator.normalizedWebURL(from: "not-a-url"))
    XCTAssertNil(LinkstrURLValidator.normalizedWebURL(from: ""))
  }

  func testRootPayloadValidationAcceptsRealProviderVideoLinks() {
    let urls = [
      "https://www.tiktok.com/@boogiebug0/video/7596114833477537054?is_from_webapp=1",
      "https://www.instagram.com/reel/DUSWiOIDivu/",
      "https://www.facebook.com/reel/213286701716863",
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://rumble.com/v8tc4h9-zelensky-has-rolled-the-world-in-less-than-2-minutes.html",
      "https://x.com/jack/status/20",
      "https://twitter.com/nyjets/status/924685391524798464/video/1",
    ]

    for url in urls {
      let payload = LinkstrPayload(
        conversationID: "c1",
        rootID: "r1",
        kind: .root,
        url: url,
        note: nil,
        timestamp: 123
      )
      XCTAssertNoThrow(try payload.validated(), "Expected valid provider URL: \(url)")
    }
  }
}
