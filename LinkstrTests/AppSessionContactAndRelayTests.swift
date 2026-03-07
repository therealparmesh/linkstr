import SwiftData
import XCTest

@testable import Linkstr

@MainActor
final class AppSessionContactAndRelayTests: AppSessionTestCase {
  func testAddContactStoresTrimmedValues() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: "  \(npub)  ", alias: "  Alice  ")
    XCTAssertTrue(didAdd)

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.npub, npub)
    XCTAssertEqual(contacts.first?.displayName, "Alice")
    XCTAssertEqual(contacts.first?.localAlias, "Alice")
    XCTAssertNotEqual(contacts.first?.encryptedAlias, "Alice")
  }

  func testAddContactRejectsDuplicateAndInvalidNPub() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let didAddDuplicate = await session.addContact(npub: "  \(npub)  ", alias: "Alice 2")
    XCTAssertFalse(didAddDuplicate)
    XCTAssertEqual(session.composeError, "this contact is already in your list.")

    let didAddInvalid = await session.addContact(npub: "not-an-npub", alias: "Bob")
    XCTAssertFalse(didAddInvalid)
    XCTAssertEqual(session.composeError, "invalid contact key (npub).")

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.npub, npub)
  }

  func testUpdateContactAliasCanSetAndClearAlias() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let contacts = try fetchContacts(in: container.mainContext)
    let alice = try XCTUnwrap(contacts.first)

    let didUpdate = session.updateContactAlias(alice, alias: "Alice Updated")
    XCTAssertTrue(didUpdate)
    XCTAssertEqual(alice.displayName, "Alice Updated")

    let didClearAlias = session.updateContactAlias(alice, alias: "   ")
    XCTAssertTrue(didClearAlias)
    XCTAssertNil(alice.localAlias)
    XCTAssertEqual(alice.displayName, alice.npub)
  }

  func testRemoveContactUpdatesLocalFollowSet() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstNPub = try TestKeyMaterialFactory.makeNPub()
    let secondNPub = try TestKeyMaterialFactory.makeNPub()

    let didAddFirst = await session.addContact(npub: firstNPub, alias: "First")
    XCTAssertTrue(didAddFirst)
    let didAddSecond = await session.addContact(npub: secondNPub, alias: "Second")
    XCTAssertTrue(didAddSecond)

    let contactsBeforeDelete = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contactsBeforeDelete.count, 2)
    let firstContact = try XCTUnwrap(
      contactsBeforeDelete.first { $0.npub == firstNPub }
    )

    let didRemove = await session.removeContact(firstContact)
    XCTAssertTrue(didRemove)

    let contactsAfterDelete = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contactsAfterDelete.count, 1)
    XCTAssertFalse(contactsAfterDelete.contains(where: { $0.npub == firstNPub }))
    XCTAssertTrue(contactsAfterDelete.contains(where: { $0.npub == secondNPub }))
  }

  func testSetSessionArchivedAffectsSessionMessages() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let conversationID = "session-archive"

    let rootInTargetSession = makeMessage(
      eventID: "root-1",
      conversationID: conversationID,
      rootID: "root-1",
      kind: .root,
      senderPubkey: "sender-a",
      receiverPubkey: "sender-b",
      ownerPubkey: ownerPubkey
    )
    let rootInDifferentSession = makeMessage(
      eventID: "root-2",
      conversationID: "session-other",
      rootID: "root-2",
      kind: .root,
      senderPubkey: "sender-b",
      receiverPubkey: "sender-a",
      ownerPubkey: ownerPubkey
    )

    container.mainContext.insert(rootInTargetSession)
    container.mainContext.insert(rootInDifferentSession)
    try container.mainContext.save()

    session.setSessionArchived(sessionID: conversationID, archived: true)
    XCTAssertTrue(rootInTargetSession.isArchived)
    XCTAssertFalse(rootInDifferentSession.isArchived)

    session.setSessionArchived(sessionID: conversationID, archived: false)
    XCTAssertFalse(rootInTargetSession.isArchived)
    XCTAssertFalse(rootInDifferentSession.isArchived)
  }

  func testUpsertSessionCanPromoteNameFromOlderEventWithoutRewindingTimestamp() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let store = SessionMessageStore(modelContext: container.mainContext)

    let newerDate = Date(timeIntervalSince1970: 200)
    let olderDate = Date(timeIntervalSince1970: 100)

    _ = try store.upsertSession(
      ownerPubkey: ownerPubkey,
      sessionID: "session-name-upgrade",
      name: "Fallback Name",
      createdByPubkey: ownerPubkey,
      updatedAt: newerDate
    )
    let updated = try store.upsertSession(
      ownerPubkey: ownerPubkey,
      sessionID: "session-name-upgrade",
      name: "Canonical Session Name",
      createdByPubkey: ownerPubkey,
      updatedAt: olderDate
    )

    XCTAssertEqual(updated.name, "Canonical Session Name")
    XCTAssertEqual(updated.updatedAt, newerDate)
  }

  func testMarkRootPostReadMarksOnlyInboundRootForThatPost() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let conversationID = "session-mark-root"

    let inboundTargetRoot = makeMessage(
      eventID: "root-inbound-target",
      conversationID: conversationID,
      rootID: "root-target",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    let outboundTargetRoot = makeMessage(
      eventID: "root-outbound-target",
      conversationID: conversationID,
      rootID: "root-target",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    let inboundOtherRoot = makeMessage(
      eventID: "root-inbound-other",
      conversationID: conversationID,
      rootID: "root-other",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(inboundTargetRoot)
    container.mainContext.insert(outboundTargetRoot)
    container.mainContext.insert(inboundOtherRoot)
    try container.mainContext.save()

    session.markRootPostRead(postID: "root-target")

    XCTAssertNotNil(inboundTargetRoot.readAt)
    XCTAssertNil(outboundTargetRoot.readAt)
    XCTAssertNil(inboundOtherRoot.readAt)
  }

  func testRelayCRUDFlow() throws {
    let (session, container) = try makeSession()

    session.addRelay(url: "https://invalid-relay.example.com")
    XCTAssertEqual(session.composeError, "enter a valid relay url (ws:// or wss://).")

    session.addRelay(url: "wss://")
    XCTAssertEqual(session.composeError, "enter a valid relay url (ws:// or wss://).")
    XCTAssertTrue(try fetchRelays(in: container.mainContext).isEmpty)

    session.addRelay(url: "wss://relay.example.com")
    var relays = try fetchRelays(in: container.mainContext)
    XCTAssertEqual(relays.count, 1)
    XCTAssertEqual(relays[0].url, "wss://relay.example.com")
    XCTAssertTrue(relays[0].isEnabled)

    session.addRelay(url: "wss://relay.example.com/")
    XCTAssertEqual(session.composeError, "that relay is already in your list.")
    relays = try fetchRelays(in: container.mainContext)
    XCTAssertEqual(relays.count, 1)

    session.toggleRelay(relays[0])
    XCTAssertFalse(relays[0].isEnabled)

    session.removeRelay(relays[0])
    relays = try fetchRelays(in: container.mainContext)
    XCTAssertTrue(relays.isEmpty)
  }

  func testResetDefaultRelaysReplacesExistingRelays() throws {
    let (session, container) = try makeSession()

    session.addRelay(url: "wss://custom.example.com")
    var relays = try fetchRelays(in: container.mainContext)
    XCTAssertEqual(relays.map(\.url), ["wss://custom.example.com"])

    session.resetDefaultRelays()
    relays = try fetchRelays(in: container.mainContext)

    XCTAssertEqual(Set(relays.map(\.url)), Set(RelayDefaults.urls))
    XCTAssertEqual(relays.count, RelayDefaults.urls.count)
    XCTAssertTrue(relays.allSatisfy(\.isEnabled))
  }
}
