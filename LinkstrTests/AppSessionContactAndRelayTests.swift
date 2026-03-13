import NostrSDK
import SwiftData
import SwiftUI
import UIKit
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

  func testAddContactOverwritesExistingAliasAndRejectsInvalidNPub() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let didAddDuplicate = await session.addContact(npub: "  \(npub)  ", alias: "Alice 2")
    XCTAssertTrue(didAddDuplicate)
    XCTAssertNil(session.composeError)

    let didAddInvalid = await session.addContact(npub: "not-an-npub", alias: "Bob")
    XCTAssertFalse(didAddInvalid)
    XCTAssertEqual(session.composeError, "invalid public key (npub).")

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.npub, npub)
    XCTAssertEqual(contacts.first?.localAlias, "Alice 2")
  }

  func testAddContactOverwriteDoesNotRepublishFollowList() async throws {
    var publishedFollowLists: [[String]] = []
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishFollowList: { followedPubkeys in
        publishedFollowLists.append(followedPubkeys)
        return "follow-list-add-contact"
      }
    )
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let didOverwrite = await session.addContact(npub: npub, alias: "Alice 2")
    XCTAssertTrue(didOverwrite)

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.localAlias, "Alice 2")
    XCTAssertEqual(publishedFollowLists.count, 1)
    XCTAssertEqual(publishedFollowLists.first, [contacts[0].targetPubkey])
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

  func testIncomingProfileMetadataBecomesFallbackDisplayNameUntilAliased() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "")
    XCTAssertTrue(didAdd)

    let initialContact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-alice",
        authorPubkey: initialContact.targetPubkey,
        createdAt: Date(timeIntervalSince1970: 120),
        chosenName: "Alice From Nostr"
      )
    )

    let initialIdentity = session.resolvedIdentity(for: initialContact)
    XCTAssertEqual(initialIdentity.displayName, "Alice From Nostr")
    XCTAssertEqual(initialIdentity.chosenName, "Alice From Nostr")
    XCTAssertNil(initialIdentity.aliasedChosenName)

    let didUpdateAlias = session.updateContactAlias(initialContact, alias: "Alice Local")
    XCTAssertTrue(didUpdateAlias)
    let resolvedIdentity = session.resolvedIdentity(for: initialContact)
    XCTAssertEqual(resolvedIdentity.displayName, "Alice Local")
    XCTAssertEqual(resolvedIdentity.aliasedChosenName, "Alice From Nostr")
  }

  func testIncomingProfileMetadataIgnoresOlderReplaceableEvent() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "")
    XCTAssertTrue(didAdd)

    let contact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-new",
        authorPubkey: contact.targetPubkey,
        createdAt: Date(timeIntervalSince1970: 200),
        chosenName: "New Name"
      )
    )
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-old",
        authorPubkey: contact.targetPubkey,
        createdAt: Date(timeIntervalSince1970: 100),
        chosenName: "Old Name"
      )
    )

    let identity = session.resolvedIdentity(for: contact)
    XCTAssertEqual(identity.displayName, "New Name")
    XCTAssertEqual(identity.chosenName, "New Name")
  }

  func testIncomingProfileMetadataCachesNamesForNonContacts() async throws {
    let (session, _) = try makeSession()
    try session.identityService.createNewIdentity()
    let participantPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-non-contact",
        authorPubkey: participantPubkey,
        createdAt: Date(timeIntervalSince1970: 220),
        chosenName: "Session Peer"
      )
    )

    XCTAssertEqual(session.remoteProfilesByPubkey.count, 1)
    XCTAssertEqual(session.remoteProfilesByPubkey[participantPubkey]?.chosenName, "Session Peer")
    XCTAssertEqual(session.displayName(for: participantPubkey, contacts: []), "Session Peer")
  }

  func testAddContactAppliesCachedKnownProfileMetadataImmediately() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let keypair = try TestKeyMaterialFactory.makeKeypair()

    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-before-follow",
        authorPubkey: keypair.publicKey.hex,
        createdAt: Date(timeIntervalSince1970: 240),
        chosenName: "Known Before Follow"
      )
    )

    let didAdd = await session.addContact(npub: keypair.publicKey.npub, alias: "")
    XCTAssertTrue(didAdd)

    let contact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    let identity = session.resolvedIdentity(for: contact)
    XCTAssertEqual(identity.chosenName, "Known Before Follow")
    XCTAssertEqual(identity.displayName, "Known Before Follow")
  }

  func testRequestRemoteProfilesIfNeededCoalescesImmediateDuplicateRequests() async throws {
    var requestedPubkeyBatches: [[String]] = []
    let (session, _) = try makeSession(
      requestProfileMetadata: { requestedPubkeys in
        requestedPubkeyBatches.append(requestedPubkeys.sorted())
      }
    )
    try session.identityService.createNewIdentity()
    let firstPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let secondPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [firstPubkey, secondPubkey, firstPubkey])
    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [firstPubkey, secondPubkey])

    XCTAssertEqual(requestedPubkeyBatches.count, 1)
    let requestedPubkeys = try XCTUnwrap(requestedPubkeyBatches.first)
    XCTAssertEqual(requestedPubkeys, [firstPubkey, secondPubkey].sorted())
  }

  func testUpdateOwnProfileNamePublishesMergedMetadataContentAndPersistsState() async throws {
    var publishedEvent: NostrEvent?
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { event in
        publishedEvent = event
        return event.id
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let existingContent =
      #"{"about":"still here","display_name":"Old Name","name":"Old Name","picture":"https://example.com/picture.png"}"#
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-self-old",
        authorPubkey: ownerPubkey,
        createdAt: Date(timeIntervalSince1970: 150),
        chosenName: "Old Name",
        rawContent: existingContent
      )
    )

    let didSave = await session.updateOwnProfileName(
      "New Name",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didSave)
    XCTAssertEqual(session.currentProfileName, "New Name")
    XCTAssertEqual(publishedEvent?.kind, .metadata)

    let publishedContentData = try XCTUnwrap(publishedEvent?.content.data(using: .utf8))
    let publishedContent = try XCTUnwrap(
      JSONSerialization.jsonObject(with: publishedContentData) as? [String: String]
    )
    XCTAssertEqual(publishedContent["name"], "New Name")
    XCTAssertEqual(publishedContent["display_name"], "New Name")
    XCTAssertEqual(publishedContent["about"], "still here")
    XCTAssertEqual(publishedContent["picture"], "https://example.com/picture.png")

    let accountState = try XCTUnwrap(fetchAccountStates(in: container.mainContext).first)
    XCTAssertEqual(accountState.nostrProfileName, "New Name")
    XCTAssertEqual(accountState.profileMetadataContent, publishedEvent?.content)
  }

  func testUpdateOwnProfileNameNormalizesWhitespaceBeforePersisting() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()

    let didSave = await session.updateOwnProfileName(
      "  Alice \n\t Bob \u{0007}  ",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didSave)
    XCTAssertEqual(session.currentProfileName, "Alice Bob")

    let accountState = try XCTUnwrap(fetchAccountStates(in: container.mainContext).first)
    let publishedContentData = try XCTUnwrap(
      accountState.profileMetadataContent?.data(using: .utf8))
    let publishedContent = try XCTUnwrap(
      JSONSerialization.jsonObject(with: publishedContentData) as? [String: String]
    )
    XCTAssertEqual(publishedContent["name"], "Alice Bob")
    XCTAssertEqual(publishedContent["display_name"], "Alice Bob")
  }

  func testUpdateOwnProfileNameRejectsOverlongNames() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let invalidName = String(repeating: "a", count: NostrProfileMetadata.maxChosenNameLength + 1)

    let didSave = await session.updateOwnProfileName(invalidName)

    XCTAssertFalse(didSave)
    XCTAssertEqual(
      session.profileNameErrorMessage,
      "profile name must be \(NostrProfileMetadata.maxChosenNameLength) characters or fewer."
    )
    XCTAssertNil(session.currentProfileName)
    XCTAssertTrue(try fetchAccountStates(in: container.mainContext).isEmpty)
  }

  func testBootRestoresPersistedOwnProfileNameState() async throws {
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { event in event.id }
    )
    try session.identityService.createNewIdentity()

    let didSave = await session.updateOwnProfileName(
      "Restored Name",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )
    XCTAssertTrue(didSave)

    var restoredOverrides = AppSession.TestingOverrides()
    restoredOverrides.skipDefaultRelaySetup = true
    restoredOverrides.skipNostrNetworkStartup = true
    let restoredSession = AppSession(
      modelContext: container.mainContext,
      testingOverrides: restoredOverrides
    )

    await restoredSession.boot()

    XCTAssertEqual(restoredSession.currentProfileName, "Restored Name")
    XCTAssertNil(restoredSession.profileNameErrorMessage)
  }

  func testBootDoesNotRestoreRemoteProfileDirectoryAcrossSessions() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let participantPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-restored-non-contact",
        authorPubkey: participantPubkey,
        createdAt: Date(timeIntervalSince1970: 260),
        chosenName: "Restored Session Peer"
      )
    )

    var restoredOverrides = AppSession.TestingOverrides()
    restoredOverrides.skipDefaultRelaySetup = true
    restoredOverrides.skipNostrNetworkStartup = true
    let restoredSession = AppSession(
      modelContext: container.mainContext,
      testingOverrides: restoredOverrides
    )

    await restoredSession.boot()

    let restoredIdentity = restoredSession.resolvedIdentity(for: participantPubkey, contacts: [])
    XCTAssertEqual(restoredIdentity.displayName, restoredIdentity.npub)
  }

  func testResolvedIdentityHidesDuplicateNPubLineWhenNoNameExists() throws {
    let pubkeyHex = try TestKeyMaterialFactory.makePubkeyHex()

    let identity = LinkstrResolvedIdentity(
      localAlias: nil,
      chosenName: nil,
      pubkeyHex: pubkeyHex
    )

    XCTAssertEqual(identity.displayName, identity.npub)
    XCTAssertFalse(identity.showsNPubLine)
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

  func testRemoveContactPublishesUpdatedFollowListBeforeLocalRemoval() async throws {
    var publishedFollowLists: [[String]] = []
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishFollowList: { followedPubkeys in
        publishedFollowLists.append(followedPubkeys)
        return "follow-list-remove-contact"
      }
    )
    try session.identityService.createNewIdentity()
    let firstNPub = try TestKeyMaterialFactory.makeNPub()
    let secondNPub = try TestKeyMaterialFactory.makeNPub()

    let didAddFirst = await session.addContact(npub: firstNPub, alias: "First")
    XCTAssertTrue(didAddFirst)
    let didAddSecond = await session.addContact(npub: secondNPub, alias: "Second")
    XCTAssertTrue(didAddSecond)

    let contactsBeforeDelete = try fetchContacts(in: container.mainContext)
    let firstContact = try XCTUnwrap(contactsBeforeDelete.first { $0.npub == firstNPub })
    let secondContact = try XCTUnwrap(contactsBeforeDelete.first { $0.npub == secondNPub })

    let didRemove = await session.removeContact(
      firstContact,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didRemove)
    XCTAssertEqual(publishedFollowLists.last, [secondContact.targetPubkey])

    let contactsAfterDelete = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contactsAfterDelete.map(\.targetPubkey), [secondContact.targetPubkey])
  }

  func testRemoveContactKeepsLocalDataWhenFollowListPublishFails() async throws {
    var publishCount = 0
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishFollowList: { _ in
        publishCount += 1
        if publishCount > 1 {
          throw NostrServiceError.publishRejected("blocked: policy")
        }
        return "follow-list-add-contact"
      }
    )
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let contact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    let didRemove = await session.removeContact(
      contact,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertFalse(didRemove)
    XCTAssertEqual(session.composeError, "blocked: policy")
    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
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

  func testVisibleSessionPostMarksInboundRootReadOnAppear() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: "session-visible-read"
    )

    let inboundRoot = makeMessage(
      eventID: "root-visible-read",
      conversationID: sessionEntity.sessionID,
      rootID: "root-visible-read",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(inboundRoot)
    try container.mainContext.save()

    let rootView = NavigationStack {
      SessionPostsView(sessionEntity: sessionEntity)
        .environmentObject(session)
    }
    .modelContainer(container)

    let hostingController = UIHostingController(rootView: rootView)
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = hostingController
    window.makeKeyAndVisible()
    let deadline = Date(timeIntervalSinceNow: 1)
    while inboundRoot.readAt == nil, Date() < deadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    XCTAssertNotNil(inboundRoot.readAt)

    window.isHidden = true
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    window.rootViewController = nil
  }

  func testCancelPendingMetadataRefreshesForHiddenSessionDropsStaleQueuedWork() async throws {
    actor PreviewRecorder {
      var requestedURLs: [String] = []

      func record(_ url: String) {
        requestedURLs.append(url)
      }

      func snapshot() -> [String] {
        requestedURLs
      }
    }

    let recorder = PreviewRecorder()
    let (session, container) = try makeSession(
      fetchLinkPreview: { url in
        await recorder.record(url)
        if url.contains("first") {
          try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return LinkPreviewData(title: "preview for \(url)", thumbnailPath: nil)
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    func makeRoot(eventID: String, url: String) throws -> SessionMessageEntity {
      try SessionMessageEntity(
        eventID: eventID,
        ownerPubkey: myPubkey,
        conversationID: "session-visible-metadata-cancel",
        rootID: eventID,
        kind: .root,
        senderPubkey: myPubkey,
        url: url,
        note: nil,
        timestamp: .now,
        linkType: .twitter
      )
    }

    let first = try makeRoot(eventID: "first", url: "metadata-test-first")
    let second = try makeRoot(eventID: "second", url: "metadata-test-second")
    let third = try makeRoot(eventID: "third", url: "metadata-test-third")
    container.mainContext.insert(first)
    container.mainContext.insert(second)
    container.mainContext.insert(third)
    try container.mainContext.save()

    session.refreshMetadataForVisiblePostIfNeeded(first)
    session.refreshMetadataForVisiblePostIfNeeded(second)

    let firstRequestDeadline = Date(timeIntervalSinceNow: 1)
    while (await recorder.snapshot()).isEmpty, Date() < firstRequestDeadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let firstSnapshot = await recorder.snapshot()
    XCTAssertEqual(firstSnapshot, ["metadata-test-first"])
    XCTAssertEqual(session.testingPendingMetadataRefreshCount, 2)

    session.cancelPendingMetadataRefreshesForHiddenSession()
    session.refreshMetadataForVisiblePostIfNeeded(third)

    let thirdRequestDeadline = Date(timeIntervalSinceNow: 1)
    while third.metadataTitle == nil, Date() < thirdRequestDeadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let finalSnapshot = await recorder.snapshot()
    XCTAssertEqual(finalSnapshot, ["metadata-test-first", "metadata-test-third"])
    XCTAssertNil(second.metadataTitle)
    XCTAssertEqual(third.metadataTitle, "preview for metadata-test-third")
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

  func testForceRestartMarksEnabledRelaysConnectingAndClearsStaleErrors() throws {
    let (session, container) = try makeSession(disableNostrStartup: false)
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(
      url: "wss://relay.example.com",
      status: .connected,
      lastError: "stale relay failure"
    )
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.startNostrIfPossible(forceRestart: true)

    let relays = try fetchRelays(in: container.mainContext)
    XCTAssertEqual(session.relayStatus(for: relay), .connecting)
    XCTAssertEqual(session.connectedRelayCount(for: relays), 0)
    XCTAssertNil(session.relayErrorMessage(for: relay))
  }

  func testPassiveOfflineToastDoesNotLoopAcrossForegroundRelayFlaps() throws {
    let (session, container) = try makeSession()
    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.beginForegroundRelayCycleForTesting()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped"
    )

    XCTAssertEqual(session.composeError, "you're offline. waiting for a relay connection.")

    session.composeError = nil
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped again"
    )

    XCTAssertNil(session.composeError)
  }

  func testPassiveOfflineToastRearmsOnNextForegroundCycle() throws {
    let (session, container) = try makeSession()
    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.beginForegroundRelayCycleForTesting()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped"
    )
    XCTAssertEqual(session.composeError, "you're offline. waiting for a relay connection.")

    session.composeError = nil
    session.beginForegroundRelayCycleForTesting()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped after reopen"
    )

    XCTAssertEqual(session.composeError, "you're offline. waiting for a relay connection.")
  }
}

@MainActor
final class NostrDMServiceTests: XCTestCase {
  func testLateRelayConnectAfterCompletedBackfillResetsCoverage() {
    let service = NostrDMService()
    service.seedBackfillCoverageForTesting(
      completedRelayURLs: ["wss://relay-a.example.com"],
      hasActiveBackfill: false,
      isCompleted: true
    )

    service.simulateLateRelayConnectionForTesting("wss://relay-b.example.com")

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 0)
    XCTAssertTrue(service.testingCompletedBackfillRelayURLs.isEmpty)
    XCTAssertTrue(service.testingCurrentBackfillRelayURLs.isEmpty)
    XCTAssertEqual(service.testingActiveBackfillCount, 0)
  }

  func testCoveredRelayConnectDoesNotResetCompletedBackfillCoverage() {
    let service = NostrDMService()
    service.seedBackfillCoverageForTesting(
      completedRelayURLs: ["wss://relay-a.example.com"],
      hasActiveBackfill: false,
      isCompleted: true
    )

    service.simulateLateRelayConnectionForTesting("wss://relay-a.example.com")

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 2)
    XCTAssertEqual(service.testingCompletedBackfillRelayURLs, ["wss://relay-a.example.com"])
  }

  func testLateRelayConnectDuringActiveBackfillResetsInFlightCoverage() {
    let service = NostrDMService()
    service.seedBackfillCoverageForTesting(
      activeRelayURLs: ["wss://relay-a.example.com"],
      hasActiveBackfill: true,
      isCompleted: false
    )

    service.simulateLateRelayConnectionForTesting("wss://relay-b.example.com")

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 0)
    XCTAssertEqual(service.testingActiveBackfillCount, 0)
    XCTAssertTrue(service.testingCurrentBackfillRelayURLs.isEmpty)
  }

  func testBackfillCoverageRefreshesAfterInitialCompletionWasAlreadyNotified() {
    let service = NostrDMService()

    service.simulateBackfillCoverageFinalizationForTesting(
      relayURLs: ["wss://relay-b.example.com"],
      initialCompletionAlreadyNotified: true
    )

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 2)
    XCTAssertEqual(service.testingCompletedBackfillRelayURLs, ["wss://relay-b.example.com"])
    XCTAssertTrue(service.testingCurrentBackfillRelayURLs.isEmpty)
  }
}
