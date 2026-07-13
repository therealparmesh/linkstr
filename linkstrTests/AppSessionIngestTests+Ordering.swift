import SwiftData
import XCTest

@testable import linkstr

// MARK: - Ordering, queuing, contacts, and dedup tests

extension AppSessionIngestTests {

  func testIngestQueuesRootUntilSessionCreateArrives() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-pending-root-create"

    ingestRoot(
      session,
      IngestOp(
        id: "root-before-session-create", sender: creatorPubkey, time: 905, sessionID: sessionID),
      url: "https://example.com/root-before-session-create",
      note: "arrived first")

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(
      try container.mainContext.fetch(FetchDescriptor<SessionEntity>()).isEmpty)

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-after-root-arrival", sender: creatorPubkey, time: 900,
        sessionID: sessionID),
      name: "Pending Root Session", members: [creatorPubkey, myPubkey])

    let sessions = try container.mainContext.fetch(
      FetchDescriptor<SessionEntity>())
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.name, "Pending Root Session")
    XCTAssertEqual(
      try fetchMessages(in: container.mainContext).map(\.eventID),
      ["root-before-session-create"])
  }

  func testIngestSessionMembersBootstrapsMissingSessionAndReplaysPendingRoot() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-bootstrap-from-members"

    ingestRoot(
      session,
      IngestOp(
        id: "root-before-bootstrap-snapshot", sender: creatorPubkey, time: 1005, sessionID: sessionID),
      url: "https://example.com/root-before-bootstrap",
      note: "late add root")

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)

    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-bootstrap", sender: creatorPubkey, time: 1000, sessionID: sessionID),
      members: [creatorPubkey, myPubkey],
      name: "Late Add Session")

    let sessionEntity = try XCTUnwrap(
      container.mainContext.fetch(FetchDescriptor<SessionEntity>()).first)
    XCTAssertEqual(sessionEntity.name, "Late Add Session")
    XCTAssertEqual(sessionEntity.createdByPubkey, creatorPubkey)
    XCTAssertEqual(
      try fetchMessages(in: container.mainContext).map(\.eventID),
      ["root-before-bootstrap-snapshot"])
  }

  func testIngestQueuesReactionUntilRootArrives() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-pending-reaction"
    let rootEventID = "root-arrives-after-reaction"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-pending-reaction", sender: creatorPubkey, time: 800, sessionID: sessionID),
      name: "Orphan Reaction",
      members: [creatorPubkey, myPubkey, peerPubkey])
    ingestReaction(
      session,
      IngestOp(id: "reaction-before-root", sender: peerPubkey, time: 810, sessionID: sessionID),
      rootID: rootEventID)

    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)

    ingestRoot(
      session, IngestOp(id: rootEventID, sender: creatorPubkey, time: 805, sessionID: sessionID),
      url: "https://example.com/root-arrives-after-reaction")

    let reactions = try fetchReactions(in: container.mainContext)
    XCTAssertEqual(reactions.count, 1)
    let reaction = try XCTUnwrap(reactions.first)
    XCTAssertEqual(reaction.postID, rootEventID)
    XCTAssertEqual(reaction.senderPubkey, peerPubkey)
    XCTAssertTrue(reaction.isActive)
  }

  func testIngestRootPostRejectsMismatchedPayloadRootID() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-rootid-guard"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-rootid-guard", sender: creatorPubkey, time: 900, sessionID: sessionID),
      name: "Root ID Guard",
      members: [creatorPubkey, myPubkey, peerPubkey])

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-event-id",
        senderPubkey: peerPubkey,
        createdAt: Date(timeIntervalSince1970: 910),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "payload-root-id",
          kind: .root,
          url: "https://example.com/root-mismatch",
          note: nil,
          timestamp: 910
        )))

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

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-reaction-tiebreak", sender: creatorPubkey, time: 1000,
        sessionID: sessionID),
      name: "Reaction Tiebreak",
      members: [creatorPubkey, myPubkey, peerPubkey])
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: peerPubkey, time: 1005, sessionID: sessionID),
      url: "https://example.com/reaction-tiebreak")
    ingestReaction(
      session, IngestOp(id: "reaction-z", sender: peerPubkey, time: 1010, sessionID: sessionID),
      rootID: rootEventID,
      active: false)
    ingestReaction(
      session, IngestOp(id: "reaction-a", sender: peerPubkey, time: 1010, sessionID: sessionID),
      rootID: rootEventID,
      active: true)

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
        eventID: "follow-z", authorPubkey: myPubkey,
        followedPubkeys: [winnerPubkey], createdAt: tieDate))
    session.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "follow-a", authorPubkey: myPubkey,
        followedPubkeys: [loserPubkey], createdAt: tieDate))

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.targetPubkey, winnerPubkey)
  }

  func testFollowListRecencyPersistsAcrossAppRestart() throws {
    let relaySettingsUserDefaults = makeRelaySettingsUserDefaults()
    let (session, container) = try makeSession(
      relaySettingsUserDefaults: relaySettingsUserDefaults)
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let nsec = try session.identityService.revealNsec()
    let winnerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let stalePubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "follow-restart-fresh", authorPubkey: myPubkey,
        followedPubkeys: [winnerPubkey],
        createdAt: Date(timeIntervalSince1970: 1200)))

    let restartedSession = AppSession(
      modelContext: container.mainContext,
      relaySettingsUserDefaults: relaySettingsUserDefaults,
      testingOverrides: {
        var overrides = AppSession.TestingOverrides()
        overrides.skipNostrNetworkStartup = true
        return overrides
      }())
    restartedSession.importNsec(nsec)

    restartedSession.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "follow-restart-stale", authorPubkey: myPubkey,
        followedPubkeys: [stalePubkey],
        createdAt: Date(timeIntervalSince1970: 1190)))

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.targetPubkey, winnerPubkey)
  }

  func testIncomingDuplicateOutgoingRootMergesPublishedTransportEventIDs() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-merge-root-wrappers"
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey], sessionID: sessionID)

    let rootPost = try makeMessage(
      eventID: "root-merge-wrapper", conversationID: sessionID,
      rootID: "root-merge-wrapper", kind: .root,
      senderPubkey: myPubkey, receiverPubkey: myPubkey,
      ownerPubkey: myPubkey,
      publishedTransportEventIDs: ["giftwrap-root-a"])
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    ingestRoot(
      session,
      IngestOp(
        id: "root-merge-wrapper", sender: myPubkey, time: Date.now.timeIntervalSince1970,
        sessionID: sessionID),
      url: "https://example.com/root-merge-wrapper",
      note: "hello", transportEventID: "giftwrap-root-b")

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(
      Set(try XCTUnwrap(messages.first).publishedTransportEventIDs),
      Set(["giftwrap-root-a", "giftwrap-root-b"]))
  }

  func testPendingRootMergesTransportEventIDsAcrossDuplicateWrappers() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-pending-root-merge-wrappers"
    let rootEventID = "root-pending-merge-wrapper"

    ingestRoot(
      session, IngestOp(id: rootEventID, sender: senderPubkey, time: 2_200, sessionID: sessionID),
      url: "https://example.com/root-pending-merge-wrapper",
      transportEventID: "giftwrap-pending-root-a", source: .historical)
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: senderPubkey, time: 2_200, sessionID: sessionID),
      url: "https://example.com/root-pending-merge-wrapper",
      transportEventID: "giftwrap-pending-root-b", source: .historical)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-after-pending-root-wrapper-merge", sender: senderPubkey, time: 2_190,
        sessionID: sessionID),
      name: "Pending Root Wrapper Merge",
      members: [senderPubkey, myPubkey], source: .historical)

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(
      Set(try XCTUnwrap(messages.first).publishedTransportEventIDs),
      Set(["giftwrap-pending-root-a", "giftwrap-pending-root-b"]))
  }
}
