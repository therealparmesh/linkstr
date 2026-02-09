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
  }

  func testReplyPayloadValidationRejectsURL() {
    let valid = LinkstrPayload(
      conversationID: "c1",
      rootID: "r1",
      kind: .reply,
      url: nil,
      note: "ok",
      timestamp: 123
    )
    XCTAssertNoThrow(try valid.validated())

    let invalid = LinkstrPayload(
      conversationID: "c1",
      rootID: "r1",
      kind: .reply,
      url: "https://example.com",
      note: "bad",
      timestamp: 123
    )
    XCTAssertThrowsError(try invalid.validated())
  }

  func testDecodeWithoutTimestampBackfillsNow() throws {
    let json = """
      {
        "conversation_id": "conversation",
        "root_id": "root",
        "kind": "reply",
        "note": "hello"
      }
      """
    let before = Int64(Date.now.timeIntervalSince1970) - 1
    let payload = try JSONDecoder().decode(LinkstrPayload.self, from: Data(json.utf8))
    let after = Int64(Date.now.timeIntervalSince1970) + 1

    XCTAssertGreaterThanOrEqual(payload.timestamp, before)
    XCTAssertLessThanOrEqual(payload.timestamp, after)
    XCTAssertEqual(payload.kind, .reply)
    XCTAssertEqual(payload.note, "hello")
    XCTAssertNil(payload.url)
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
}
