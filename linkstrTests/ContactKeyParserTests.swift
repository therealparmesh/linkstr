import XCTest

@testable import linkstr

final class ContactKeyParserTests: XCTestCase {
  func testExtractNPubFromSupportedInputShapes() throws {
    let npub = try TestKeyMaterialFactory.makeNPub()

    let cases = [
      ("raw value", npub),
      ("nostr prefix", "nostr:\(npub)"),
      ("query item", "https://example.com/add?npub=\(npub)"),
      ("freeform text", "Add this contact: \(npub) thanks"),
    ]

    for (label, input) in cases {
      XCTAssertEqual(ContactKeyParser.extractNPub(from: input), npub, label)
    }
  }

  func testExtractNPubRejectsInvalidInput() {
    XCTAssertNil(ContactKeyParser.extractNPub(from: ""))
    XCTAssertNil(ContactKeyParser.extractNPub(from: "not-an-npub"))
    XCTAssertNil(ContactKeyParser.extractNPub(from: "nostr:npub1invalid"))
  }
}
