import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

@MainActor
final class AppSessionLocalFlowTests: XCTestCase {
  override func setUpWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
  }

  override func tearDownWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
  }

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

  func testRelayConnectivityStateClassification() throws {
    let (session, _) = try makeSession()

    XCTAssertEqual(session.relayConnectivityState(for: []), .noEnabledRelays)
    XCTAssertEqual(
      session.relayConnectivityState(for: [
        RelayEntity(url: "wss://one.example.com", status: .connected)
      ]),
      .online
    )
    XCTAssertEqual(
      session.relayConnectivityState(for: [
        RelayEntity(url: "wss://one.example.com", status: .connecting)
      ]),
      .connecting
    )
    XCTAssertEqual(
      session.relayConnectivityState(for: [
        RelayEntity(url: "wss://one.example.com", status: .readOnly)
      ]),
      .readOnly
    )
    XCTAssertEqual(
      session.relayConnectivityState(
        for: [RelayEntity(url: "wss://one.example.com", status: .disconnected)]
      ),
      .offline
    )
    XCTAssertEqual(
      session.relayConnectivityState(for: [
        RelayEntity(url: "wss://one.example.com", status: .failed)
      ]),
      .offline
    )
    XCTAssertEqual(
      session.relayConnectivityState(
        for: [
          RelayEntity(url: "wss://one.example.com", status: .disconnected),
          RelayEntity(url: "wss://two.example.com", status: .connected),
        ]
      ),
      .online
    )
  }

  func testCreateSessionPostAwaitingRelayTimesOutWhenRelayNeverConnects() async throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com", status: .disconnected))
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "couldn't reconnect to relays in time. try again.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionSetsPendingNavigationID() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let peerNPub = try TestKeyMaterialFactory.makeNPub()

    let didCreate = await session.createSessionAwaitingRelay(
      name: "Navigation Session",
      memberNPubs: [peerNPub]
    )

    XCTAssertTrue(didCreate)
    let sessions = try container.mainContext.fetch(
      FetchDescriptor<SessionEntity>(sortBy: [SortDescriptor(\.createdAt)]))
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(session.pendingSessionNavigationID, sessions.first?.sessionID)

    session.clearPendingSessionNavigationID()
    XCTAssertNil(session.pendingSessionNavigationID)
  }

  func testCreateSessionPostAwaitingRelaySendsWhenLiveRelayConnectionExists() async throws {
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testRelaySendOverride: { _, _ in "await-root-event" }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com", status: .failed))
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didCreate)
    XCTAssertNil(session.composeError)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
  }

  func testCreateSessionPostAwaitingRelayWithReadOnlyRelaysShowsReadOnlyMessage() async throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com", status: .readOnly))
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError,
      "connected relays are read-only. add a writable relay to send."
    )
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostAwaitingRelayWithNoEnabledRelaysShowsNoEnabledRelaysMessage()
    async throws
  {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError, "no relays are enabled. enable at least one relay in settings.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostPersistsOutgoingRootMessage() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: "hello",
      session: sessionEntity
    )

    XCTAssertTrue(didCreate)
    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    let message = try XCTUnwrap(messages.first)
    XCTAssertEqual(message.kind, .root)
    XCTAssertEqual(message.url, "https://example.com/path")
    XCTAssertEqual(message.note, "hello")
    XCTAssertNotEqual(message.encryptedURL, "https://example.com/path")
    XCTAssertNotEqual(message.encryptedNote, "hello")
    XCTAssertNotNil(message.readAt)
    XCTAssertFalse(message.eventID.isEmpty)
    XCTAssertNil(session.composeError)
  }

  func testCreateSessionPostRejectsInvalidURL() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "not-a-url",
      note: nil,
      session: sessionEntity
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "enter a valid url.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testUpdateSessionMembersAwaitingRelayRequiresSessionCreator() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-creator-guard"
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [myPubkey, creatorPubkey, peerPubkey],
      sessionID: sessionID
    )
    let peerNPub = try XCTUnwrap(PublicKey(hex: peerPubkey)?.npub)

    let didUpdate = await session.updateSessionMembersAwaitingRelay(
      session: sessionEntity,
      memberNPubs: [peerNPub]
    )

    XCTAssertFalse(didUpdate)
    XCTAssertEqual(session.composeError, "only the session creator can manage members.")

    let members = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(Set(members.map(\.memberPubkey)), Set([myPubkey, creatorPubkey, peerPubkey]))
  }

  func testUpdateSessionMembersAwaitingRelayBroadcastsToPriorAndNextMembers() async throws {
    var capturedRecipients: [String] = []
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testRelaySendOverride: { _, recipients in
        capturedRecipients = recipients
        return "session-members-event"
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let priorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let removedPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let addedPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let priorNPub = try XCTUnwrap(PublicKey(hex: priorPubkey)?.npub)
    let addedNPub = try XCTUnwrap(PublicKey(hex: addedPubkey)?.npub)
    let sessionID = "session-broadcast-fanout"

    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, priorPubkey, removedPubkey],
      sessionID: sessionID
    )

    let relay = RelayEntity(url: "wss://relay.example.com", status: .connected)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    let didUpdate = await session.updateSessionMembersAwaitingRelay(
      session: sessionEntity,
      memberNPubs: [priorNPub, addedNPub]
    )

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(
      Set(capturedRecipients),
      Set([myPubkey, priorPubkey, removedPubkey, addedPubkey])
    )

    let activeMembers = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(
      Set(activeMembers.map(\.memberPubkey)), Set([myPubkey, priorPubkey, addedPubkey]))
  }

  func testCreateSessionPostAwaitingRelayRequiresActiveSessionMembership() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [creatorPubkey, peerPubkey],
      sessionID: "session-no-membership-send"
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: "hello",
      session: sessionEntity
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "you're no longer a member of this session.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testToggleReactionAwaitingRelayRequiresActiveSessionMembership() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-no-membership-react"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [creatorPubkey, peerPubkey],
      sessionID: sessionID
    )

    let post = makeMessage(
      eventID: "react-target",
      conversationID: sessionID,
      rootID: "react-target",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(post)
    try container.mainContext.save()

    let didToggle = await session.toggleReactionAwaitingRelay(emoji: "👍", post: post)

    XCTAssertFalse(didToggle)
    XCTAssertEqual(session.composeError, "you're no longer a member of this session.")
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
  }

  func testIngestMembershipLifecycleHonorsMembershipWindows() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-membership-lifecycle"

    let createdAt = Date(timeIntervalSince1970: 100)
    let beforeRemoval = Date(timeIntervalSince1970: 110)
    let removedAt = Date(timeIntervalSince1970: 120)
    let duringRemoval = Date(timeIntervalSince1970: 130)
    let readdedAt = Date(timeIntervalSince1970: 140)
    let afterReadd = Date(timeIntervalSince1970: 150)
    let backfillBeforeRemoval = Date(timeIntervalSince1970: 115)
    let backfillDuringRemoval = Date(timeIntervalSince1970: 135)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-1",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: createdAt,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: Int64(createdAt.timeIntervalSince1970),
          sessionName: "Lifecycle Session",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-before-removal",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: beforeRemoval,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-before-removal",
          kind: .root,
          url: "https://example.com/before-removal",
          note: nil,
          timestamp: Int64(beforeRemoval.timeIntervalSince1970)
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-remove",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: removedAt,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-remove",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: Int64(removedAt.timeIntervalSince1970),
          memberPubkeys: [creatorPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-during-removal",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: duringRemoval,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-during-removal",
          kind: .root,
          url: "https://example.com/during-removal",
          note: nil,
          timestamp: Int64(duringRemoval.timeIntervalSince1970)
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-readd",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: readdedAt,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-readd",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: Int64(readdedAt.timeIntervalSince1970),
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-after-readd",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: afterReadd,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-after-readd",
          kind: .root,
          url: "https://example.com/after-readd",
          note: nil,
          timestamp: Int64(afterReadd.timeIntervalSince1970)
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-backfill-before-removal",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: backfillBeforeRemoval,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-backfill-before-removal",
          kind: .root,
          url: "https://example.com/backfill-before",
          note: nil,
          timestamp: Int64(backfillBeforeRemoval.timeIntervalSince1970)
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-backfill-during-removal",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: backfillDuringRemoval,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-backfill-during-removal",
          kind: .root,
          url: "https://example.com/backfill-during",
          note: nil,
          timestamp: Int64(backfillDuringRemoval.timeIntervalSince1970)
        )
      ))

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(
      Set(messages.map(\.eventID)),
      Set([
        "root-before-removal",
        "root-after-readd",
        "root-backfill-before-removal",
      ])
    )
  }

  func testIngestIgnoresNonCreatorMembershipMutations() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let attackerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-non-creator-mutation"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-2",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 200),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 200,
          sessionName: "Creator Session",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-attacker",
        senderPubkey: attackerPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 210),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-attack",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 210,
          memberPubkeys: [attackerPubkey, myPubkey]
        )
      ))

    let activeMembers = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(
      Set(activeMembers.map(\.memberPubkey)), Set([creatorPubkey, myPubkey, peerPubkey]))
  }

  func testIngestIgnoresReactionFromInactiveMember() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-membership-guard"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-3",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 300),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 300,
          sessionName: "Reaction Guard",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-remove-peer",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 310),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-remove",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 310,
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-from-removed-peer",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 320),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "missing-root",
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 320,
          emoji: "👀",
          reactionActive: true
        )
      ))

    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
  }

  func testIngestSessionCreateRequiresSenderAndReceiverInMemberSnapshot() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-missing-sender",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 400),
        payload: LinkstrPayload(
          conversationID: "session-create-guard-1",
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 400,
          sessionName: "Missing Sender",
          memberPubkeys: [myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-missing-receiver",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 410),
        payload: LinkstrPayload(
          conversationID: "session-create-guard-2",
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 410,
          sessionName: "Missing Receiver",
          memberPubkeys: [creatorPubkey, peerPubkey]
        )
      ))

    let sessions = try container.mainContext.fetch(FetchDescriptor<SessionEntity>())
    XCTAssertTrue(sessions.isEmpty)
  }

  func testMembershipSnapshotIgnoresOlderBackfillThatAddsUnseenMembers() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let removedPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let stalePubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-membership-backfill-guard"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-membership-guard",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 500),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 500,
          sessionName: "Membership Guard",
          memberPubkeys: [creatorPubkey, myPubkey, removedPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-membership-remove",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 600),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-remove",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 600,
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-membership-stale-backfill",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 550),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-stale",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 550,
          memberPubkeys: [creatorPubkey, myPubkey, stalePubkey]
        )
      ))

    let activeMembers = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))

    XCTAssertEqual(Set(activeMembers.map(\.memberPubkey)), Set([creatorPubkey, myPubkey]))
    XCTAssertFalse(activeMembers.contains(where: { $0.memberPubkey == stalePubkey }))
    XCTAssertFalse(activeMembers.contains(where: { $0.memberPubkey == removedPubkey }))
  }

  func testMembershipSnapshotUsesEventIDTiebreakForEqualTimestamp() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let winnerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let loserPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-membership-tiebreak"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-tiebreak",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 700),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 700,
          sessionName: "Tiebreak",
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    let tieDate = Date(timeIntervalSince1970: 710)
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-z",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: tieDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-z",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 710,
          memberPubkeys: [creatorPubkey, myPubkey, winnerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-a",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: tieDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-a",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 710,
          memberPubkeys: [creatorPubkey, myPubkey, loserPubkey]
        )
      ))

    let activeMembers = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(
      Set(activeMembers.map(\.memberPubkey)), Set([creatorPubkey, myPubkey, winnerPubkey]))
    XCTAssertFalse(activeMembers.contains(where: { $0.memberPubkey == loserPubkey }))
  }

  func testIngestIgnoresReactionWithoutRootPost() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-orphan-reaction-guard"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-orphan-reaction",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 800),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 800,
          sessionName: "Orphan Reaction",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-without-root",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 810),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-does-not-exist",
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 810,
          emoji: "👍",
          reactionActive: true
        )
      ))

    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
  }

  func testIngestRootPostRejectsMismatchedPayloadRootID() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-rootid-guard"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-rootid-guard",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 900),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 900,
          sessionName: "Root ID Guard",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-event-id",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 910),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "payload-root-id",
          kind: .root,
          url: "https://example.com/root-mismatch",
          note: nil,
          timestamp: 910
        )
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testReactionStateUsesEventIDTiebreakForEqualTimestamp() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-tiebreak"
    let rootEventID = "root-for-reaction-tiebreak"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-reaction-tiebreak",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1000),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1000,
          sessionName: "Reaction Tiebreak",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1005),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/reaction-tiebreak",
          note: nil,
          timestamp: 1005
        )
      ))

    let tieDate = Date(timeIntervalSince1970: 1010)
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-z",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: tieDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 1010,
          emoji: "👍",
          reactionActive: false
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-a",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: tieDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 1010,
          emoji: "👍",
          reactionActive: true
        )
      ))

    let reactions = try fetchReactions(in: container.mainContext)
    XCTAssertEqual(reactions.count, 1)
    XCTAssertFalse(try XCTUnwrap(reactions.first).isActive)
  }

  func testFollowListUsesEventIDTiebreakForEqualTimestamp() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let winnerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let loserPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let tieDate = Date(timeIntervalSince1970: 1100)

    session.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "follow-z",
        authorPubkey: myPubkey,
        followedPubkeys: [winnerPubkey],
        createdAt: tieDate
      ))

    session.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "follow-a",
        authorPubkey: myPubkey,
        followedPubkeys: [loserPubkey],
        createdAt: tieDate
      ))

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.targetPubkey, winnerPubkey)
  }

  func testLogoutClearLocalDataRemovesContactsAndMessages() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()
    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let message = makeMessage(
      eventID: "message-1",
      conversationID: "conversation-1",
      rootID: "message-1",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: "me",
      ownerPubkey: try XCTUnwrap(session.identityService.pubkeyHex)
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    session.logout(clearLocalData: true)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testLogoutWithoutClearingLocalDataKeepsContactsAndMessages() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()
    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let message = makeMessage(
      eventID: "message-2",
      conversationID: "conversation-2",
      rootID: "message-2",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: "me",
      ownerPubkey: try XCTUnwrap(session.identityService.pubkeyHex)
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    session.logout(clearLocalData: false)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
  }

  func testLogoutClearLocalDataRemovesStoredThumbnailFiles() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let thumbnailURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("linkstr-thumbnail-\(UUID().uuidString).png")
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)

    let message = makeMessage(
      eventID: "message-thumbnail",
      conversationID: "conversation-thumbnail",
      rootID: "message-thumbnail",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Title", thumbnailURL: thumbnailURL.path)
    container.mainContext.insert(message)
    try container.mainContext.save()

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))

    session.logout(clearLocalData: true)

    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
  }

  func testContactDuplicationIsScopedPerAccount() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    let sharedNPub = try TestKeyMaterialFactory.makeNPub()
    let didAddFirst = await session.addContact(npub: sharedNPub, alias: "Alice-A")
    XCTAssertTrue(didAddFirst)

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logout(clearLocalData: false)
    session.importNsec(secondKeypair.privateKey.nsec)
    let secondOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    XCTAssertNotEqual(firstOwner, secondOwner)

    let didAddSecond = await session.addContact(npub: sharedNPub, alias: "Alice-B")
    XCTAssertTrue(didAddSecond)

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 2)
    XCTAssertEqual(Set(contacts.map(\.ownerPubkey)).count, 2)
  }

  func testSameEventIDCanBeStoredForDifferentAccounts() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)

    let firstMessage = makeMessage(
      eventID: "shared-event-id",
      conversationID: "conversation-a",
      rootID: "shared-event-id",
      kind: .root,
      senderPubkey: "peer-a",
      receiverPubkey: firstOwner,
      ownerPubkey: firstOwner
    )
    container.mainContext.insert(firstMessage)
    try container.mainContext.save()

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logout(clearLocalData: false)
    session.importNsec(secondKeypair.privateKey.nsec)
    let secondOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    XCTAssertNotEqual(firstOwner, secondOwner)

    let secondMessage = makeMessage(
      eventID: "shared-event-id",
      conversationID: "conversation-b",
      rootID: "shared-event-id",
      kind: .root,
      senderPubkey: "peer-b",
      receiverPubkey: secondOwner,
      ownerPubkey: secondOwner
    )
    container.mainContext.insert(secondMessage)
    XCTAssertNoThrow(try container.mainContext.save())

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(Set(messages.map(\.ownerPubkey)).count, 2)
    XCTAssertEqual(Set(messages.map(\.storageID)).count, 2)
  }

  func testCreateSessionPostAwaitingRelayDoesNotPersistWhenRelayRejectsPublish() async throws {
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testRelaySendOverride: { _, _ in
        throw NostrServiceError.publishRejected("blocked: policy")
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    let relay = RelayEntity(url: "wss://relay.example.com", status: .connected)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "blocked: policy")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  private func insertSessionFixture(
    in context: ModelContext,
    ownerPubkey: String,
    createdByPubkey: String,
    memberPubkeys: [String],
    name: String = "Test Session",
    sessionID: String = "session-fixture"
  ) throws -> SessionEntity {
    let createdAt = Date.now
    let sessionEntity = try SessionEntity(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      name: name,
      createdByPubkey: createdByPubkey,
      createdAt: createdAt,
      updatedAt: createdAt
    )
    context.insert(sessionEntity)

    for memberPubkey in Set(memberPubkeys) {
      let member = try SessionMemberEntity(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkey: memberPubkey,
        isActive: true,
        createdAt: createdAt,
        updatedAt: createdAt
      )
      context.insert(member)

      let interval = try SessionMemberIntervalEntity(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkey: memberPubkey,
        startAt: createdAt
      )
      context.insert(interval)
    }

    try context.save()
    return sessionEntity
  }

  private func makeSession(
    testDisableNostrStartupOverride: Bool? = nil,
    testHasConnectedRelaysOverride: (() -> Bool)? = nil,
    testRelaySendOverride: ((LinkstrPayload, [String]) async throws -> String)? = nil
  ) throws -> (
    AppSession, ModelContainer
  ) {
    let schema = Schema([
      ContactEntity.self,
      RelayEntity.self,
      SessionEntity.self,
      SessionMemberEntity.self,
      SessionMemberIntervalEntity.self,
      SessionReactionEntity.self,
      SessionMessageEntity.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return (
      AppSession(
        modelContext: container.mainContext,
        testDisableNostrStartupOverride: testDisableNostrStartupOverride,
        testHasConnectedRelaysOverride: testHasConnectedRelaysOverride,
        testRelaySendOverride: testRelaySendOverride,
        testSkipNostrNetworkStartup: true
      ),
      container
    )
  }

  private func fetchContacts(in context: ModelContext) throws -> [ContactEntity] {
    try context.fetch(FetchDescriptor<ContactEntity>(sortBy: [SortDescriptor(\.createdAt)]))
  }

  private func fetchRelays(in context: ModelContext) throws -> [RelayEntity] {
    try context.fetch(FetchDescriptor<RelayEntity>(sortBy: [SortDescriptor(\.createdAt)]))
  }

  private func fetchMessages(in context: ModelContext) throws -> [SessionMessageEntity] {
    try context.fetch(
      FetchDescriptor<SessionMessageEntity>(sortBy: [SortDescriptor(\.timestamp)]))
  }

  private func fetchReactions(in context: ModelContext) throws -> [SessionReactionEntity] {
    try context.fetch(
      FetchDescriptor<SessionReactionEntity>(sortBy: [SortDescriptor(\.updatedAt)]))
  }

  private func makeIncomingMessage(
    eventID: String,
    senderPubkey: String,
    receiverPubkey: String,
    createdAt: Date,
    payload: LinkstrPayload
  ) -> ReceivedDirectMessage {
    ReceivedDirectMessage(
      eventID: eventID,
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      payload: payload,
      createdAt: createdAt
    )
  }

  private func makeMessage(
    eventID: String,
    conversationID: String,
    rootID: String,
    kind: SessionMessageKind,
    senderPubkey: String,
    receiverPubkey: String,
    ownerPubkey: String
  ) -> SessionMessageEntity {
    guard
      let message = try? SessionMessageEntity(
        eventID: eventID,
        ownerPubkey: ownerPubkey,
        conversationID: conversationID,
        rootID: rootID,
        kind: kind,
        senderPubkey: senderPubkey,
        receiverPubkey: receiverPubkey,
        url: "https://example.com/\(eventID)",
        note: "note-\(eventID)",
        timestamp: .now,
        readAt: nil,
        linkType: .generic
      )
    else {
      fatalError("Failed building test message for \(eventID)")
    }
    return message
  }
}

enum TestKeyMaterialFactory {
  static func makeKeypair() throws -> Keypair {
    guard let keypair = Keypair() else {
      throw TestKeyMaterialFactoryError.keypairGenerationFailed
    }
    return keypair
  }

  static func makeNPub() throws -> String {
    try makeKeypair().publicKey.npub
  }

  static func makePubkeyHex() throws -> String {
    try makeKeypair().publicKey.hex
  }
}

enum TestKeyMaterialFactoryError: Error {
  case keypairGenerationFailed
}
