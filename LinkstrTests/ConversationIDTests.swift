import XCTest

@testable import Linkstr

final class ConversationIDTests: XCTestCase {
  func testDeterministicAcrossOrderAndCase() {
    let lhs = "ABCDEF123456"
    let rhs = "deadbeef9999"

    let first = ConversationID.deterministic(lhs, rhs)
    let second = ConversationID.deterministic(rhs.uppercased(), lhs.lowercased())

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.count, 64)
  }

  func testDifferentPeersYieldDifferentConversationIDs() {
    let first = ConversationID.deterministic("aa11", "bb22")
    let second = ConversationID.deterministic("aa11", "cc33")
    XCTAssertNotEqual(first, second)
  }
}
