import XCTest

@testable import Linkstr

final class RecipientSelectionLogicTests: XCTestCase {
  func testSelectedQueryPrefersDisplayName() {
    XCTAssertEqual(
      RecipientSelectionLogic.selectedQuery(
        selectedRecipientNPub: "npub1example",
        selectedDisplayName: "Alice"
      ),
      "Alice"
    )
  }

  func testSelectedQueryFallsBackToNPub() {
    XCTAssertEqual(
      RecipientSelectionLogic.selectedQuery(
        selectedRecipientNPub: "npub1example",
        selectedDisplayName: "   "
      ),
      "npub1example"
    )
  }

  func testContactMatchesMatchesDisplayNameCaseInsensitive() {
    XCTAssertTrue(
      RecipientSelectionLogic.contactMatches(
        query: "alice",
        displayName: "Alice Smith",
        npub: "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk3el7l"
      )
    )
  }

  func testContactMatchesMatchesNPubSubstring() {
    XCTAssertTrue(
      RecipientSelectionLogic.contactMatches(
        query: "npub1test",
        displayName: "Bob",
        npub: "npub1testabcdefg12345"
      )
    )
  }

  func testContactMatchesRejectsNonMatchingQuery() {
    XCTAssertFalse(
      RecipientSelectionLogic.contactMatches(
        query: "charlie",
        displayName: "Alice Smith",
        npub: "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk3el7l"
      )
    )
  }

  func testNormalizedNPubAcceptsRawAndNostrPrefix() throws {
    let npub = try TestKeyMaterialFactory.makeNPub()
    XCTAssertEqual(RecipientSelectionLogic.normalizedNPub(from: npub), npub)
    XCTAssertEqual(RecipientSelectionLogic.normalizedNPub(from: "nostr:\(npub)"), npub)
  }

  func testNormalizedNPubRejectsInvalidValue() {
    XCTAssertNil(RecipientSelectionLogic.normalizedNPub(from: "not-an-npub"))
  }

  func testCustomRecipientNPubReturnsNilForKnownContactNPub() throws {
    let known = try TestKeyMaterialFactory.makeNPub()
    XCTAssertNil(
      RecipientSelectionLogic.customRecipientNPub(
        from: known,
        knownNPubs: [known]
      )
    )
  }

  func testCustomRecipientNPubReturnsNormalizedForUnknownNPub() throws {
    let known = try TestKeyMaterialFactory.makeNPub()
    let custom = try TestKeyMaterialFactory.makeNPub()
    XCTAssertEqual(
      RecipientSelectionLogic.customRecipientNPub(
        from: "nostr:\(custom)",
        knownNPubs: [known]
      ),
      custom
    )
  }

  func testRecipientLabelPrimaryUsesContactDisplayName() {
    XCTAssertEqual(
      NewPostRecipientLabelLogic.primaryLabel(
        activeRecipientNPub: "npub1example",
        matchedContactDisplayName: "Alice"
      ),
      "Alice"
    )
  }

  func testRecipientLabelPrimaryFallsBackToNPubForUnknownContact() {
    XCTAssertEqual(
      NewPostRecipientLabelLogic.primaryLabel(
        activeRecipientNPub: "npub1example",
        matchedContactDisplayName: nil
      ),
      "npub1example"
    )
  }

  func testRecipientLabelSecondaryShowsNPubWhenDisplayNameExists() {
    XCTAssertEqual(
      NewPostRecipientLabelLogic.secondaryLabel(
        activeRecipientNPub: "npub1example",
        matchedContactDisplayName: "Alice"
      ),
      "npub1example"
    )
  }

  func testRecipientLabelSecondaryIsNilForUnknownContact() {
    XCTAssertNil(
      NewPostRecipientLabelLogic.secondaryLabel(
        activeRecipientNPub: "npub1example",
        matchedContactDisplayName: nil
      )
    )
  }
}
