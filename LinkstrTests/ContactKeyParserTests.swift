import XCTest

@testable import Linkstr

final class ContactKeyParserTests: XCTestCase {
  func testExtractNPubFromRawValue() throws {
    let npub = try TestKeyMaterialFactory.makeNPub()
    XCTAssertEqual(ContactKeyParser.extractNPub(from: npub), npub)
  }

  func testExtractNPubFromNostrPrefix() throws {
    let npub = try TestKeyMaterialFactory.makeNPub()
    XCTAssertEqual(ContactKeyParser.extractNPub(from: "nostr:\(npub)"), npub)
  }

  func testExtractNPubFromQueryItem() throws {
    let npub = try TestKeyMaterialFactory.makeNPub()
    let url = "https://example.com/add?npub=\(npub)"
    XCTAssertEqual(ContactKeyParser.extractNPub(from: url), npub)
  }

  func testExtractNPubFromFreeformText() throws {
    let npub = try TestKeyMaterialFactory.makeNPub()
    let text = "Add this contact: \(npub) thanks"
    XCTAssertEqual(ContactKeyParser.extractNPub(from: text), npub)
  }

  func testExtractNPubRejectsInvalidInput() {
    XCTAssertNil(ContactKeyParser.extractNPub(from: ""))
    XCTAssertNil(ContactKeyParser.extractNPub(from: "not-an-npub"))
    XCTAssertNil(ContactKeyParser.extractNPub(from: "nostr:npub1invalid"))
  }
}
