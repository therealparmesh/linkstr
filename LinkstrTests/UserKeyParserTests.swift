import NostrSDK
import XCTest

@testable import Linkstr

final class UserKeyParserTests: XCTestCase {
  func testExtractNPubFromRawValue() throws {
    let npub = try makeNPub()
    XCTAssertEqual(UserKeyParser.extractNPub(from: npub), npub)
  }

  func testExtractNPubFromNostrPrefix() throws {
    let npub = try makeNPub()
    XCTAssertEqual(UserKeyParser.extractNPub(from: "nostr:\(npub)"), npub)
  }

  func testExtractNPubFromQueryItem() throws {
    let npub = try makeNPub()
    let url = "https://example.com/add?npub=\(npub)"
    XCTAssertEqual(UserKeyParser.extractNPub(from: url), npub)
  }

  func testExtractNPubFromFreeformText() throws {
    let npub = try makeNPub()
    let text = "Add this contact: \(npub) thanks"
    XCTAssertEqual(UserKeyParser.extractNPub(from: text), npub)
  }

  func testExtractNPubRejectsInvalidInput() {
    XCTAssertNil(UserKeyParser.extractNPub(from: ""))
    XCTAssertNil(UserKeyParser.extractNPub(from: "not-an-npub"))
    XCTAssertNil(UserKeyParser.extractNPub(from: "nostr:npub1invalid"))
  }

  private func makeNPub() throws -> String {
    guard let keypair = Keypair() else {
      throw TestError.keypairGenerationFailed
    }
    return keypair.publicKey.npub
  }
}

private enum TestError: Error {
  case keypairGenerationFailed
}
