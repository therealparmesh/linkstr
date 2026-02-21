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

  func testAddContactStoresTrimmedValues() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = session.addContact(npub: "  \(npub)  ", displayName: "  Alice  ")
    XCTAssertTrue(didAdd)

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.npub, npub)
    XCTAssertEqual(contacts.first?.displayName, "Alice")
    XCTAssertNotEqual(contacts.first?.encryptedNPub, npub)
    XCTAssertNotEqual(contacts.first?.encryptedDisplayName, "Alice")
  }

  func testAddContactRejectsDuplicateAndInvalidNPub() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    withExtendedLifetime(container) {
      let didAdd = session.addContact(npub: npub, displayName: "Alice")
      XCTAssertTrue(didAdd)

      let didAddDuplicate = session.addContact(npub: npub, displayName: "Alice 2")
      XCTAssertFalse(didAddDuplicate)
      XCTAssertEqual(session.composeError, "This contact is already in your list.")

      let didAddInvalid = session.addContact(npub: "not-an-npub", displayName: "Bob")
      XCTAssertFalse(didAddInvalid)
      XCTAssertEqual(session.composeError, "Invalid Contact Key (npub).")
    }
  }

  func testAddContactRejectsDuplicateAcrossWhitespaceVariant() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    withExtendedLifetime(container) {
      let didAdd = session.addContact(npub: npub, displayName: "Alice")
      XCTAssertTrue(didAdd)

      let didAddDuplicate = session.addContact(npub: "  \(npub)  ", displayName: "Alice 2")
      XCTAssertFalse(didAddDuplicate)
      XCTAssertEqual(session.composeError, "This contact is already in your list.")
    }
  }

  func testUpdateContactHappyPathAndDuplicateGuard() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstNPub = try TestKeyMaterialFactory.makeNPub()
    let secondNPub = try TestKeyMaterialFactory.makeNPub()
    let replacementNPub = try TestKeyMaterialFactory.makeNPub()

    let didAddFirst = session.addContact(npub: firstNPub, displayName: "Alice")
    XCTAssertTrue(didAddFirst)

    let didAddSecond = session.addContact(npub: secondNPub, displayName: "Bob")
    XCTAssertTrue(didAddSecond)

    let contacts = try fetchContacts(in: container.mainContext)
    let alice = try XCTUnwrap(contacts.first { $0.displayName == "Alice" })

    let didUpdateWithDuplicate = session.updateContact(
      alice,
      npub: secondNPub,
      displayName: "Alice Updated"
    )
    XCTAssertFalse(didUpdateWithDuplicate)
    XCTAssertEqual(session.composeError, "This contact is already in your list.")

    let didUpdate = session.updateContact(
      alice, npub: replacementNPub, displayName: "Alice Updated")
    XCTAssertTrue(didUpdate)
    XCTAssertEqual(alice.npub, replacementNPub)
    XCTAssertEqual(alice.displayName, "Alice Updated")
  }

  func testSetConversationArchivedAffectsOnlyRootMessages() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let conversationID = ConversationID.deterministic("sender-a", "sender-b")

    let root = makeMessage(
      eventID: "root-1",
      conversationID: conversationID,
      rootID: "root-1",
      kind: .root,
      senderPubkey: "sender-a",
      receiverPubkey: "sender-b",
      ownerPubkey: ownerPubkey
    )
    let reply = makeMessage(
      eventID: "reply-1",
      conversationID: conversationID,
      rootID: "root-1",
      kind: .reply,
      senderPubkey: "sender-b",
      receiverPubkey: "sender-a",
      ownerPubkey: ownerPubkey
    )

    container.mainContext.insert(root)
    container.mainContext.insert(reply)
    try container.mainContext.save()

    session.setConversationArchived(conversationID: conversationID, archived: true)
    XCTAssertTrue(root.isArchived)
    XCTAssertFalse(reply.isArchived)

    session.setConversationArchived(conversationID: conversationID, archived: false)
    XCTAssertFalse(root.isArchived)
    XCTAssertFalse(reply.isArchived)
  }

  func testMarkConversationPostsReadMarksOnlyInboundRootPosts() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let conversationID = ConversationID.deterministic(myPubkey, peerPubkey)

    let inboundRoot = makeMessage(
      eventID: "root-inbound",
      conversationID: conversationID,
      rootID: "root-inbound",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    let outboundRoot = makeMessage(
      eventID: "root-outbound",
      conversationID: conversationID,
      rootID: "root-outbound",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    let inboundReply = makeMessage(
      eventID: "reply-inbound",
      conversationID: conversationID,
      rootID: "root-inbound",
      kind: .reply,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )

    container.mainContext.insert(inboundRoot)
    container.mainContext.insert(outboundRoot)
    container.mainContext.insert(inboundReply)
    try container.mainContext.save()

    session.markConversationPostsRead(conversationID: conversationID)

    XCTAssertNotNil(inboundRoot.readAt)
    XCTAssertNil(outboundRoot.readAt)
    XCTAssertNil(inboundReply.readAt)
  }

  func testMarkPostRepliesReadMarksOnlyInboundRepliesForThatPost() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let conversationID = ConversationID.deterministic(myPubkey, peerPubkey)

    let inboundReply = makeMessage(
      eventID: "reply-inbound-target",
      conversationID: conversationID,
      rootID: "root-target",
      kind: .reply,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    let outboundReply = makeMessage(
      eventID: "reply-outbound-target",
      conversationID: conversationID,
      rootID: "root-target",
      kind: .reply,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    let inboundReplyDifferentRoot = makeMessage(
      eventID: "reply-inbound-other",
      conversationID: conversationID,
      rootID: "root-other",
      kind: .reply,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )

    container.mainContext.insert(inboundReply)
    container.mainContext.insert(outboundReply)
    container.mainContext.insert(inboundReplyDifferentRoot)
    try container.mainContext.save()

    session.markPostRepliesRead(postID: "root-target")

    XCTAssertNotNil(inboundReply.readAt)
    XCTAssertNil(outboundReply.readAt)
    XCTAssertNil(inboundReplyDifferentRoot.readAt)
  }

  func testRelayCRUDFlow() throws {
    let (session, container) = try makeSession()

    session.addRelay(url: "https://invalid-relay.example.com")
    XCTAssertEqual(session.composeError, "Enter a valid relay URL (ws:// or wss://).")

    session.addRelay(url: "wss://")
    XCTAssertEqual(session.composeError, "Enter a valid relay URL (ws:// or wss://).")
    XCTAssertTrue(try fetchRelays(in: container.mainContext).isEmpty)

    session.addRelay(url: "wss://relay.example.com")
    var relays = try fetchRelays(in: container.mainContext)
    XCTAssertEqual(relays.count, 1)
    XCTAssertEqual(relays[0].url, "wss://relay.example.com")
    XCTAssertTrue(relays[0].isEnabled)

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
        RelayEntity(url: "wss://one.example.com", status: .readOnly)
      ]),
      .readOnly
    )
    XCTAssertEqual(
      session.relayConnectivityState(
        for: [RelayEntity(url: "wss://one.example.com", status: .reconnecting)]
      ),
      .reconnecting
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
          RelayEntity(url: "wss://one.example.com", status: .reconnecting),
          RelayEntity(url: "wss://two.example.com", status: .connected),
        ]
      ),
      .online
    )
  }

  func testCreatePostWithOnlyReconnectingRelaysShowsReconnectingMessage() throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(url: "wss://relay.example.com", status: .reconnecting)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.composeError = "You're offline. Waiting for a relay connection."
    let didCreate = session.createPost(
      url: "https://example.com/path",
      note: nil,
      recipientNPub: recipientNPub
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "Relays are reconnecting. Try again in a moment.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreatePostWithOnlyPersistedOnlineStatusStillRequiresLiveRelaySocket() throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(url: "wss://relay.example.com", status: .connected)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    let didCreate = session.createPost(
      url: "https://example.com/path",
      note: nil,
      recipientNPub: recipientNPub
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "You're offline. Waiting for a relay connection.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreatePostWithReadOnlyRelaysShowsReadOnlyMessage() throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(url: "wss://relay.example.com", status: .readOnly)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    let didCreate = session.createPost(
      url: "https://example.com/path",
      note: nil,
      recipientNPub: recipientNPub
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError,
      "Connected relays are read-only. Add a writable relay to send."
    )
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreatePostWithOfflineRelaysShowsOfflineToast() throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(url: "wss://relay.example.com", status: .failed)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    let didCreate = session.createPost(
      url: "https://example.com/path",
      note: nil,
      recipientNPub: recipientNPub
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "You're offline. Waiting for a relay connection.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreatePostAllowsSendWhenLiveRelayConnectionExistsDespiteOfflineStoredStatus() throws {
    let (session, container) = try makeSession(
      testDisableNostrStartupOverride: false,
      testHasConnectedRelaysOverride: { true }
    )
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(url: "wss://relay.example.com", status: .failed)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.startNostrIfPossible()
    let didCreate = session.createPost(
      url: "https://example.com/path",
      note: nil,
      recipientNPub: recipientNPub
    )

    XCTAssertTrue(didCreate)
    XCTAssertNil(session.composeError)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
  }

  func testCreatePostWithNoEnabledRelaysShowsNoEnabledRelaysMessage() throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()

    let didCreate = session.createPost(
      url: "https://example.com/path",
      note: nil,
      recipientNPub: recipientNPub
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError, "No relays are enabled. Enable at least one relay in Settings.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreatePostPersistsOutgoingRootMessage() throws {
    let (session, container) = try makeSession()
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()
    session.startNostrIfPossible()

    session.createPost(
      url: "https://example.com/path",
      note: "hello",
      recipientNPub: recipientNPub
    )

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

  func testCreatePostRejectsInvalidURL() throws {
    let (session, container) = try makeSession()
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()
    session.startNostrIfPossible()

    session.createPost(url: "not-a-url", note: nil, recipientNPub: recipientNPub)

    XCTAssertEqual(session.composeError, "Enter a valid URL.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreatePostRejectsUnsupportedScheme() throws {
    let (session, container) = try makeSession()
    let recipientNPub = try TestKeyMaterialFactory.makeNPub()
    try session.identityService.createNewIdentity()
    session.startNostrIfPossible()

    session.createPost(url: "ftp://example.com/file.mp4", note: nil, recipientNPub: recipientNPub)

    XCTAssertEqual(session.composeError, "Enter a valid URL.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testSendReplyPersistsOutgoingReplyMessage() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    session.startNostrIfPossible()

    let root = makeMessage(
      eventID: "root-abc",
      conversationID: ConversationID.deterministic(myPubkey, peerPubkey),
      rootID: "root-abc",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(root)
    try container.mainContext.save()

    session.sendReply(text: "reply text", post: root)

    let replies = try fetchMessages(in: container.mainContext).filter { $0.kind == .reply }
    XCTAssertEqual(replies.count, 1)
    let reply = try XCTUnwrap(replies.first)
    XCTAssertEqual(reply.note, "reply text")
    XCTAssertEqual(reply.rootID, "root-abc")
    XCTAssertEqual(reply.senderPubkey, myPubkey)
    XCTAssertEqual(reply.receiverPubkey, peerPubkey)
    XCTAssertNotNil(reply.readAt)
    XCTAssertNil(session.composeError)
  }

  func testSendReplyWithReconnectingRelaysReturnsFalseAndDoesNotPersistReply() throws {
    let (session, container) = try makeSession(testDisableNostrStartupOverride: false)
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    let relay = RelayEntity(url: "wss://relay.example.com", status: .reconnecting)
    container.mainContext.insert(relay)

    let root = makeMessage(
      eventID: "root-reconnecting",
      conversationID: ConversationID.deterministic(myPubkey, peerPubkey),
      rootID: "root-reconnecting",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(root)
    try container.mainContext.save()

    let didSend = session.sendReply(text: "reply text", post: root)

    XCTAssertFalse(didSend)
    XCTAssertEqual(session.composeError, "Relays are reconnecting. Try again in a moment.")
    XCTAssertTrue(
      try fetchMessages(in: container.mainContext).filter { $0.kind == .reply }.isEmpty
    )
  }

  func testLogoutClearLocalDataRemovesContactsAndMessages() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()
    let didAdd = session.addContact(npub: npub, displayName: "Alice")
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

  func testLogoutWithoutClearingLocalDataKeepsContactsAndMessages() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()
    let didAdd = session.addContact(npub: npub, displayName: "Alice")
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

  func testContactDuplicationIsScopedPerAccount() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    let sharedNPub = try TestKeyMaterialFactory.makeNPub()
    XCTAssertTrue(session.addContact(npub: sharedNPub, displayName: "Alice-A"))

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logout(clearLocalData: false)
    session.importNsec(secondKeypair.privateKey.nsec)
    let secondOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    XCTAssertNotEqual(firstOwner, secondOwner)

    XCTAssertTrue(session.addContact(npub: sharedNPub, displayName: "Alice-B"))

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

  func testBootNormalizationSkipsUndecryptablePeerKeys() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let receiverPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let legacyConversationID = "legacy-conversation-id"

    let message = makeMessage(
      eventID: "legacy-normalization-message",
      conversationID: legacyConversationID,
      rootID: "legacy-normalization-message",
      kind: .root,
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      ownerPubkey: ownerPubkey
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    try LocalDataCrypto.shared.clearKey(ownerPubkey: ownerPubkey)

    session.boot()

    let storedMessage = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(storedMessage.conversationID, legacyConversationID)
  }

  private func makeSession(
    testDisableNostrStartupOverride: Bool? = nil,
    testHasConnectedRelaysOverride: (() -> Bool)? = nil
  ) throws -> (
    AppSession, ModelContainer
  ) {
    let schema = Schema([
      ContactEntity.self,
      RelayEntity.self,
      SessionMessageEntity.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return (
      AppSession(
        modelContext: container.mainContext,
        testDisableNostrStartupOverride: testDisableNostrStartupOverride,
        testHasConnectedRelaysOverride: testHasConnectedRelaysOverride
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

  private func makeMessage(
    eventID: String,
    conversationID: String,
    rootID: String,
    kind: SessionMessageKind,
    senderPubkey: String,
    receiverPubkey: String,
    ownerPubkey: String
  ) -> SessionMessageEntity {
    try! SessionMessageEntity(
      eventID: eventID,
      ownerPubkey: ownerPubkey,
      conversationID: conversationID,
      rootID: rootID,
      kind: kind,
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      url: kind == .root ? "https://example.com/\(eventID)" : nil,
      note: "note-\(eventID)",
      timestamp: .now,
      readAt: nil,
      linkType: .generic
    )
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
