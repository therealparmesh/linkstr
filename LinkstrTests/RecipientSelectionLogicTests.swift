import XCTest

@testable import Linkstr

final class RecipientSelectionLogicTests: XCTestCase {
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

final class RecipientSearchLogicTests: XCTestCase {
  private struct TestContact {
    let npub: String
    let displayName: String
  }

  func testSelectedQueryPrefersDisplayName() {
    XCTAssertEqual(
      RecipientSearchLogic.selectedQuery(
        selectedRecipientNPub: "npub1example",
        selectedDisplayName: "Alice"
      ),
      "Alice"
    )
  }

  func testSelectedQueryFallsBackToNPub() {
    XCTAssertEqual(
      RecipientSearchLogic.selectedQuery(
        selectedRecipientNPub: "npub1example",
        selectedDisplayName: "   "
      ),
      "npub1example"
    )
  }

  func testDisplayNameOrNPubFallsBackWhenDisplayNameIsEmpty() {
    XCTAssertEqual(
      RecipientSearchLogic.displayNameOrNPub(displayName: "   ", npub: "npub1example"),
      "npub1example"
    )
  }

  func testFilteredContactsReturnsAllForEmptyQuery() throws {
    let contacts = try makeContacts()
    XCTAssertEqual(
      RecipientSearchLogic.filteredContacts(
        contacts,
        query: "   ",
        displayName: \.displayName,
        npub: \.npub
      )
      .map(\.npub),
      contacts.map(\.npub)
    )
  }

  func testFilteredContactsMatchesDisplayNameCaseInsensitive() throws {
    let contacts = try makeContacts()
    let matches = RecipientSearchLogic.filteredContacts(
      contacts,
      query: "alice",
      displayName: \.displayName,
      npub: \.npub
    )
    XCTAssertEqual(matches.map(\.displayName), ["Alice Smith"])
  }

  func testFilteredContactsMatchesNPubSubstring() throws {
    let contacts = try makeContacts()
    let bobNPub = contacts[1].npub
    let suffix = String(bobNPub.suffix(10))
    let matches = RecipientSearchLogic.filteredContacts(
      contacts,
      query: suffix,
      displayName: \.displayName,
      npub: \.npub
    )
    XCTAssertEqual(matches.map(\.npub), [bobNPub])
  }

  private func makeContacts() throws -> [TestContact] {
    [
      TestContact(npub: try TestKeyMaterialFactory.makeNPub(), displayName: "Alice Smith"),
      TestContact(npub: try TestKeyMaterialFactory.makeNPub(), displayName: "Bob"),
    ]
  }
}
