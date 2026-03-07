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
      testRelaySendOverride: { _, _ in
        SentPayloadReceipt(
          rumorEventID: "await-root-event",
          publishedEventIDs: ["giftwrap-await-root-1", "giftwrap-await-root-2"]
        )
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

  func testCreateSessionPostPersistsPublishedTransportEventIDsFromRelayReceipt() async throws {
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testRelaySendOverride: { _, _ in
        SentPayloadReceipt(
          rumorEventID: "root-rumor-id",
          publishedEventIDs: ["giftwrap-root-a", "giftwrap-root-b"]
        )
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

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: "hello",
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didCreate)
    let message = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(message.eventID, "root-rumor-id")
    XCTAssertEqual(message.rootID, "root-rumor-id")
    XCTAssertEqual(message.publishedTransportEventIDs, ["giftwrap-root-a", "giftwrap-root-b"])
  }

  func testDeletePostClearsLocalRootReactionsAndPersistsDeletionWatermarkWhenNostrIsDisabled()
    async throws
  {
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
      url: "https://example.com/delete-me",
      note: "bye",
      session: sessionEntity
    )
    XCTAssertTrue(didCreate)

    let rootPost = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    let reaction = try SessionReactionEntity(
      ownerPubkey: myPubkey,
      sessionID: sessionEntity.sessionID,
      postID: rootPost.rootID,
      emoji: "🔥",
      senderPubkey: peerPubkey,
      isActive: true,
      eventID: "reaction-delete-root"
    )
    container.mainContext.insert(reaction)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(rootPost)

    XCTAssertTrue(didDelete)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.sessionID, sessionEntity.sessionID)
    XCTAssertEqual(deletions.first?.rootID, rootPost.rootID)
    XCTAssertEqual(deletions.first?.deletedByPubkey, myPubkey)
  }

  func testDeletePostAwaitingRelayUsesStoredGiftWrapIDsAndBroadcastsToKnownFormerMembers()
    async throws
  {
    var capturedRecipients: [String] = []
    var publishedDeletionEvent: NostrEvent?
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testRelayEventPublishOverride: { event in
        publishedDeletionEvent = event
        return "kind5-delete-event"
      },
      testRelaySendOverride: { payload, recipients in
        XCTAssertEqual(payload.kind, .rootDelete)
        capturedRecipients = recipients
        return SentPayloadReceipt(
          rumorEventID: "giftwrap-delete-event",
          publishedEventIDs: ["giftwrap-delete-wrapper"]
        )
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let activePeerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let formerPeerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-fanout"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, activePeerPubkey, formerPeerPubkey],
      sessionID: sessionID
    )

    let formerMember = try XCTUnwrap(
      container.mainContext.fetch(
        FetchDescriptor<SessionMemberEntity>(
          predicate: #Predicate {
            $0.ownerPubkey == myPubkey
              && $0.sessionID == sessionID
              && $0.isActive == true
          }
        )
      ).first(where: { $0.memberPubkey == formerPeerPubkey })
    )
    formerMember.isActive = false
    try container.mainContext.save()

    let rootPost = makeMessage(
      eventID: "root-delete-fanout",
      conversationID: sessionID,
      rootID: "root-delete-fanout",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: activePeerPubkey,
      ownerPubkey: myPubkey,
      publishedTransportEventIDs: ["giftwrap-root-delete-a", "giftwrap-root-delete-b"]
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(
      rootPost,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didDelete)
    let deletionEvent = try XCTUnwrap(publishedDeletionEvent)
    XCTAssertEqual(deletionEvent.kind.rawValue, EventKind.deletion.rawValue)
    XCTAssertEqual(
      Set(deletionEvent.tags.filter { $0.name == "e" }.map(\.value)),
      Set(["giftwrap-root-delete-a", "giftwrap-root-delete-b"])
    )
    XCTAssertEqual(
      deletionEvent.tags.filter { $0.name == "k" }.map(\.value),
      [String(EventKind.giftWrap.rawValue)]
    )
    XCTAssertEqual(Set(capturedRecipients), Set([myPubkey, activePeerPubkey, formerPeerPubkey]))
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertEqual(try fetchPostDeletions(in: container.mainContext).count, 1)
  }

  func testDeletePostRemovesStoredThumbnailAndCachedMediaFiles() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-files"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let thumbnailURL = makeManagedThumbnailURL()
    let cachedMediaURL = makeManagedVideoURL()
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    try Data("media".utf8).write(to: cachedMediaURL, options: .atomic)

    let rootPost = makeMessage(
      eventID: "root-delete-files",
      conversationID: sessionID,
      rootID: "root-delete-files",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    try rootPost.setMetadata(title: "delete files", thumbnailURL: thumbnailURL.path)
    rootPost.cachedMediaPath = cachedMediaURL.path
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMediaURL.path))

    let didDelete = await session.deletePostAwaitingRelay(rootPost)

    XCTAssertTrue(didDelete)
    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedMediaURL.path))
  }

  func testDeletePostDoesNotRemoveUnmanagedLocalFiles() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-unmanaged-files"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let thumbnailURL = makeUnmanagedTempURL(prefix: "linkstr-delete-thumb", fileExtension: "png")
    let cachedMediaURL = makeUnmanagedTempURL(prefix: "linkstr-delete-media", fileExtension: "mp4")
    defer {
      try? FileManager.default.removeItem(at: thumbnailURL)
      try? FileManager.default.removeItem(at: cachedMediaURL)
    }
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    try Data("media".utf8).write(to: cachedMediaURL, options: .atomic)

    let rootPost = makeMessage(
      eventID: "root-delete-unmanaged-files",
      conversationID: sessionID,
      rootID: "root-delete-unmanaged-files",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    try rootPost.setMetadata(title: "delete unmanaged files", thumbnailURL: thumbnailURL.path)
    rootPost.cachedMediaPath = cachedMediaURL.path
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(rootPost)

    XCTAssertTrue(didDelete)
    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMediaURL.path))
  }

  func testDeletePostAwaitingRelayWarnsWhenPublishedTransportIDsAreUnavailable() async throws {
    var didPublishDeletionEvent = false
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testRelayEventPublishOverride: { _ in
        didPublishDeletionEvent = true
        return "unexpected-kind5-delete"
      },
      testRelaySendOverride: { payload, _ in
        XCTAssertEqual(payload.kind, .rootDelete)
        return SentPayloadReceipt(
          rumorEventID: "root-delete-watermark",
          publishedEventIDs: ["root-delete-wrapper"]
        )
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-legacy-root"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let rootPost = makeMessage(
      eventID: "legacy-root-delete",
      conversationID: sessionID,
      rootID: "legacy-root-delete",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(
      rootPost,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didDelete)
    XCTAssertFalse(didPublishDeletionEvent)
    XCTAssertEqual(
      session.composeError,
      "post deleted, but relay deletion is unavailable for older copies of this post."
    )
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertEqual(try fetchPostDeletions(in: container.mainContext).count, 1)
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
        return SentPayloadReceipt(
          rumorEventID: "session-members-event",
          publishedEventIDs: ["session-members-wrapper"]
        )
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

  func testIngestIgnoresBackdatedRootFromCurrentlyInactiveMember() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-backdated-inactive"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-backdated-root-guard",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1600),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1600,
          sessionName: "Backdated Root Guard",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-remove-backdated-root-peer",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1610),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-remove",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 1610,
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-backdated-from-removed-peer",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1605),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-backdated-from-removed-peer",
          kind: .root,
          url: "https://example.com/backdated-root-removed-peer",
          note: nil,
          timestamp: 1605
        )
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testIngestAllowsHistoricalRootFromInactiveMemberWhenTimestampWasActive() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let removedPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-historical-root-from-removed-member"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-historical-root-guard",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1800),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1800,
          sessionName: "Historical Root Guard",
          memberPubkeys: [creatorPubkey, myPubkey, removedPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-remove-historical-root-peer",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1810),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-remove",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 1810,
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-historical-from-removed-peer",
        senderPubkey: removedPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1805),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-historical-from-removed-peer",
          kind: .root,
          url: "https://example.com/historical-root-removed-peer",
          note: nil,
          timestamp: 1805
        ),
        source: .historical
      ))

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.map(\.eventID), ["root-historical-from-removed-peer"])
  }

  func testIngestIgnoresBackdatedReactionFromCurrentlyInactiveMember() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-backdated-inactive"
    let rootEventID = "root-backdated-reaction-target"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-backdated-reaction-guard",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1700),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1700,
          sessionName: "Backdated Reaction Guard",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1704),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/backdated-reaction-target",
          note: nil,
          timestamp: 1704
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-remove-backdated-reaction-peer",
        senderPubkey: creatorPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1710),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-remove",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 1710,
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-backdated-from-removed-peer",
        senderPubkey: peerPubkey,
        receiverPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1705),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 1705,
          emoji: "👍",
          reactionActive: true
        )
      ))

    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
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

  func testIngestRootDeleteRemovesMatchingStoredPostAndReactions() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: senderPubkey,
      memberPubkeys: [myPubkey, senderPubkey],
      sessionID: sessionID
    )

    let rootPost = makeMessage(
      eventID: "root-delete-target",
      conversationID: sessionID,
      rootID: "root-delete-target",
      kind: .root,
      senderPubkey: senderPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(rootPost)
    let reaction = try SessionReactionEntity(
      ownerPubkey: myPubkey,
      sessionID: sessionID,
      postID: rootPost.rootID,
      emoji: "🔥",
      senderPubkey: myPubkey,
      isActive: true,
      eventID: "reaction-root-delete-target"
    )
    container.mainContext.insert(reaction)
    try container.mainContext.save()

    let deletionDate = Date(timeIntervalSince1970: 815)
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-delete-event",
        senderPubkey: senderPubkey,
        receiverPubkey: myPubkey,
        createdAt: deletionDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootPost.rootID,
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: Int64(deletionDate.timeIntervalSince1970)
        )
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.rootID, rootPost.rootID)
    XCTAssertEqual(deletions.first?.deletedByPubkey, senderPubkey)
  }

  func testIngestRootDeleteBeforeRootPostPreventsLaterInsert() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-precedes-post"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: senderPubkey,
      memberPubkeys: [myPubkey, senderPubkey],
      sessionID: sessionID
    )

    let deletionDate = Date(timeIntervalSince1970: 1_500)
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-delete-preseed",
        senderPubkey: senderPubkey,
        receiverPubkey: myPubkey,
        createdAt: deletionDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-preseed",
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: Int64(deletionDate.timeIntervalSince1970)
        ),
        source: .historical
      ))

    let rootDate = Date(timeIntervalSince1970: 1_450)
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-preseed",
        senderPubkey: senderPubkey,
        receiverPubkey: myPubkey,
        createdAt: rootDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-preseed",
          kind: .root,
          url: "https://example.com/preseed",
          note: nil,
          timestamp: Int64(rootDate.timeIntervalSince1970)
        ),
        source: .historical
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.rootID, "root-preseed")
  }

  func testIngestRootDeleteIgnoresMismatchedSender() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let rootSenderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let differentSenderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-mismatch"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: rootSenderPubkey,
      memberPubkeys: [myPubkey, rootSenderPubkey, differentSenderPubkey],
      sessionID: sessionID
    )

    let rootPost = makeMessage(
      eventID: "root-mismatch-target",
      conversationID: sessionID,
      rootID: "root-mismatch-target",
      kind: .root,
      senderPubkey: rootSenderPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let deletionDate = Date(timeIntervalSince1970: 1_600)
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-delete-mismatch",
        senderPubkey: differentSenderPubkey,
        receiverPubkey: myPubkey,
        createdAt: deletionDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootPost.rootID,
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: Int64(deletionDate.timeIntervalSince1970)
        )
      ))

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.rootID, rootPost.rootID)
    XCTAssertTrue(try fetchPostDeletions(in: container.mainContext).isEmpty)
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

  func testFollowListRecencyPersistsAcrossAppRestart() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let nsec = try session.identityService.revealNsec()
    let winnerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let stalePubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "follow-restart-fresh",
        authorPubkey: myPubkey,
        followedPubkeys: [winnerPubkey],
        createdAt: Date(timeIntervalSince1970: 1200)
      ))

    let restartedSession = AppSession(
      modelContext: container.mainContext,
      testSkipNostrNetworkStartup: true
    )
    restartedSession.importNsec(nsec)

    restartedSession.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "follow-restart-stale",
        authorPubkey: myPubkey,
        followedPubkeys: [stalePubkey],
        createdAt: Date(timeIntervalSince1970: 1190)
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
    XCTAssertEqual(try fetchAccountStates(in: container.mainContext).count, 1)

    session.logout(clearLocalData: true)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchAccountStates(in: container.mainContext).isEmpty)
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

  func testDeleteAccountClearsLocalDataAndIdentityWhenNostrNetworkIsDisabled() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let message = makeMessage(
      eventID: "message-delete-account",
      conversationID: "conversation-delete-account",
      rootID: "message-delete-account",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    container.mainContext.insert(message)

    let reaction = try SessionReactionEntity(
      ownerPubkey: ownerPubkey,
      sessionID: "conversation-delete-account",
      postID: "message-delete-account",
      emoji: "🔥",
      senderPubkey: "peer",
      isActive: true,
      eventID: "reaction-delete-account"
    )
    container.mainContext.insert(reaction)
    try container.mainContext.save()

    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchReactions(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchAccountStates(in: container.mainContext).count, 1)

    let didDelete = await session.deleteAccountAwaitingRelay()

    XCTAssertTrue(didDelete)
    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchAccountStates(in: container.mainContext).isEmpty)
  }

  func testDeleteAccountAwaitingRelayPublishesFollowListAndVanishBeforeLocalCleanup()
    async throws
  {
    var publishedFollowLists: [[String]] = []
    var publishedEventKinds: [Int] = []
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testFollowListPublishOverride: { followedPubkeys in
        publishedFollowLists.append(followedPubkeys)
        return "follow-list-delete-account"
      },
      testRelayEventPublishOverride: { event in
        publishedEventKinds.append(event.kind.rawValue)
        return "vanish-delete-account"
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)
    let message = makeMessage(
      eventID: "message-delete-account-online",
      conversationID: "conversation-delete-account-online",
      rootID: "message-delete-account-online",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    let didDelete = await session.deleteAccountAwaitingRelay(
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didDelete)
    XCTAssertEqual(publishedFollowLists.last, [])
    XCTAssertEqual(publishedEventKinds, [62])
    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testDeleteAccountAwaitingRelayKeepsLocalDataWhenRelayPublishFails() async throws {
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true },
      testFollowListPublishOverride: { _ in "follow-list-delete-account" },
      testRelayEventPublishOverride: { _ in
        throw NostrServiceError.publishRejected("blocked: policy")
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)
    let message = makeMessage(
      eventID: "message-delete-account-failure",
      conversationID: "conversation-delete-account-failure",
      rootID: "message-delete-account-failure",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    let didDelete = await session.deleteAccountAwaitingRelay(
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didDelete)
    XCTAssertEqual(session.composeError, "blocked: policy")
    XCTAssertNotNil(session.identityService.keypair)
    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
  }

  func testIncomingDuplicateOutgoingRootMergesPublishedTransportEventIDs() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-merge-root-wrappers"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let rootPost = makeMessage(
      eventID: "root-merge-wrapper",
      conversationID: sessionID,
      rootID: "root-merge-wrapper",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey,
      publishedTransportEventIDs: ["giftwrap-root-a"]
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-merge-wrapper",
        transportEventID: "giftwrap-root-b",
        senderPubkey: myPubkey,
        receiverPubkey: myPubkey,
        createdAt: .now,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-merge-wrapper",
          kind: .root,
          url: "https://example.com/root-merge-wrapper",
          note: "hello",
          timestamp: Int64(Date.now.timeIntervalSince1970)
        )
      )
    )

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(
      Set(try XCTUnwrap(messages.first).publishedTransportEventIDs),
      Set(["giftwrap-root-a", "giftwrap-root-b"])
    )
  }

  func testReactionSummaryBadgeTextCapsAtTenPlus() {
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 1, includesCurrentUser: false).badgeText,
      "1"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 10, includesCurrentUser: false).badgeText,
      "10"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 11, includesCurrentUser: false).badgeText,
      "10+"
    )
  }

  func testReactionSummaryReadOnlyBadgeTextHidesSingleReaction() {
    XCTAssertNil(
      ReactionSummary(emoji: "🔥", count: 1, includesCurrentUser: false).readOnlyBadgeText
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 2, includesCurrentUser: false).readOnlyBadgeText,
      "2"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 12, includesCurrentUser: false).readOnlyBadgeText,
      "10+"
    )
  }

  func testTwitterEmbedDocumentDefersRevealAndPostsMetrics() {
    let html = TwitterEmbedDocumentBuilder.documentHTML(from: "<blockquote>tweet</blockquote>")

    XCTAssertTrue(html.contains("body.linkstr-embed-ready"))
    XCTAssertTrue(html.contains("opacity: 0"))
    XCTAssertTrue(html.contains("linkstrEmbedMetrics"))
    XCTAssertTrue(html.contains("MutationObserver"))
    XCTAssertTrue(html.contains("ResizeObserver"))
  }

  func testIncomingReactionNotificationBodyUsesPreviewWhenAvailable() {
    XCTAssertEqual(
      LocalNotificationService.incomingReactionBody(emoji: "🔥", postPreview: "A very good post"),
      "reacted with 🔥 to A very good post"
    )
    XCTAssertEqual(
      LocalNotificationService.incomingReactionBody(emoji: "🔥", postPreview: nil),
      "reacted with 🔥"
    )
    XCTAssertEqual(
      LocalNotificationService.incomingReactionBody(emoji: "🔥", postPreview: "   "),
      "reacted with 🔥"
    )
  }

  func testLogoutClearLocalDataRemovesStoredThumbnailFiles() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let thumbnailURL = makeManagedThumbnailURL()
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

  func testLogoutClearLocalDataDoesNotRemoveUnmanagedThumbnailFiles() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let thumbnailURL = makeUnmanagedTempURL(
      prefix: "linkstr-unmanaged-thumbnail",
      fileExtension: "png"
    )
    defer { try? FileManager.default.removeItem(at: thumbnailURL) }
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)

    let message = makeMessage(
      eventID: "message-unmanaged-thumbnail",
      conversationID: "conversation-unmanaged-thumbnail",
      rootID: "message-unmanaged-thumbnail",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Title", thumbnailURL: thumbnailURL.path)
    container.mainContext.insert(message)
    try container.mainContext.save()

    session.logout(clearLocalData: true)

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
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
    testFollowListPublishOverride: (([String]) async throws -> String)? = nil,
    testRelayEventPublishOverride: ((NostrEvent) async throws -> String)? = nil,
    testRelaySendOverride: ((LinkstrPayload, [String]) async throws -> SentPayloadReceipt)? = nil
  ) throws -> (
    AppSession, ModelContainer
  ) {
    let schema = Schema([
      AccountStateEntity.self,
      ContactEntity.self,
      RelayEntity.self,
      SessionEntity.self,
      SessionMemberEntity.self,
      SessionMemberIntervalEntity.self,
      SessionReactionEntity.self,
      SessionPostDeletionEntity.self,
      SessionMessageEntity.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return (
      AppSession(
        modelContext: container.mainContext,
        testDisableNostrStartupOverride: testDisableNostrStartupOverride,
        testHasConnectedRelaysOverride: testHasConnectedRelaysOverride,
        testFollowListPublishOverride: testFollowListPublishOverride,
        testRelayEventPublishOverride: testRelayEventPublishOverride,
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

  private func fetchPostDeletions(in context: ModelContext) throws -> [SessionPostDeletionEntity] {
    try context.fetch(
      FetchDescriptor<SessionPostDeletionEntity>(sortBy: [SortDescriptor(\.updatedAt)]))
  }

  private func fetchAccountStates(in context: ModelContext) throws -> [AccountStateEntity] {
    try context.fetch(FetchDescriptor<AccountStateEntity>())
  }

  private func makeManagedThumbnailURL() -> URL {
    ManagedLocalFileScope.shared.thumbnailFileURL(
      for: "test-thumbnail-\(UUID().uuidString)",
      fileExtension: "png"
    )
  }

  private func makeManagedVideoURL() -> URL {
    ManagedLocalFileScope.shared.cachedVideoFileURL(
      for: URL(string: "https://example.com/video-\(UUID().uuidString).mp4")!,
      preferredExtension: "mp4"
    )
  }

  private func makeUnmanagedTempURL(prefix: String, fileExtension: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(prefix)-\(UUID().uuidString).\(fileExtension)")
  }

  private func makeIncomingMessage(
    eventID: String,
    transportEventID: String? = nil,
    senderPubkey: String,
    receiverPubkey: String,
    createdAt: Date,
    payload: LinkstrPayload,
    source: DirectMessageIngestSource = .live
  ) -> ReceivedDirectMessage {
    ReceivedDirectMessage(
      eventID: eventID,
      transportEventID: transportEventID,
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      payload: payload,
      createdAt: createdAt,
      source: source
    )
  }

  private func makeMessage(
    eventID: String,
    conversationID: String,
    rootID: String,
    kind: SessionMessageKind,
    senderPubkey: String,
    receiverPubkey: String,
    ownerPubkey: String,
    publishedTransportEventIDs: [String] = []
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
        linkType: .generic,
        publishedTransportEventIDs: publishedTransportEventIDs
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
