import NostrSDK
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import linkstr

extension AppSessionContactAndRelayTests {
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
    let relaySettingsUserDefaults = makeRelaySettingsUserDefaults()
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { event in event.id },
      relaySettingsUserDefaults: relaySettingsUserDefaults
    )
    try session.identityService.createNewIdentity()

    let didSave = await session.updateOwnProfileName(
      "Restored Name",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )
    XCTAssertTrue(didSave)

    var restoredOverrides = AppSession.TestingOverrides()
    restoredOverrides.skipNostrNetworkStartup = true
    let restoredSession = AppSession(
      modelContext: container.mainContext,
      relaySettingsUserDefaults: relaySettingsUserDefaults,
      testingOverrides: restoredOverrides
    )

    await restoredSession.boot()

    XCTAssertEqual(restoredSession.currentProfileName, "Restored Name")
    XCTAssertNil(restoredSession.profileNameErrorMessage)
  }

  func testBootDoesNotRestoreRemoteProfileDirectoryAcrossSessions() async throws {
    let relaySettingsUserDefaults = makeRelaySettingsUserDefaults()
    let (session, container) = try makeSession(
      relaySettingsUserDefaults: relaySettingsUserDefaults
    )
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
    restoredOverrides.skipNostrNetworkStartup = true
    let restoredSession = AppSession(
      modelContext: container.mainContext,
      relaySettingsUserDefaults: relaySettingsUserDefaults,
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

    let rootInTargetSession = try makeMessage(
      eventID: "root-1",
      conversationID: conversationID,
      rootID: "root-1",
      kind: .root,
      senderPubkey: "sender-a",
      receiverPubkey: "sender-b",
      ownerPubkey: ownerPubkey
    )
    let rootInDifferentSession = try makeMessage(
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

  func testUpsertSessionPreservesExistingNameWhenTouchingOlderEvent() throws {
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

    XCTAssertEqual(updated.name, "Fallback Name")
    XCTAssertEqual(updated.updatedAt, newerDate)
  }

  func testMarkRootPostReadMarksOnlyInboundRootForThatPost() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let conversationID = "session-mark-root"

    let inboundTargetRoot = try makeMessage(
      eventID: "root-inbound-target",
      conversationID: conversationID,
      rootID: "root-target",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    let outboundTargetRoot = try makeMessage(
      eventID: "root-outbound-target",
      conversationID: conversationID,
      rootID: "root-target",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    let inboundOtherRoot = try makeMessage(
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

    let inboundRoot = try makeMessage(
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
      SessionPostsView(
        ownerPubkey: myPubkey,
        sessionID: sessionEntity.sessionID
      )
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
}
