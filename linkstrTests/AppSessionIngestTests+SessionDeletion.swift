import SwiftData
import XCTest

@testable import linkstr

// MARK: - Session deletion and rename tests

extension AppSessionIngestTests {

  func testIngestSessionDeletePurgesStoredSessionDataAndPersistsTombstone() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-ingest"
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [myPubkey, creatorPubkey, peerPubkey],
      sessionID: sessionID)

    let rootPost = try makeMessage(
      eventID: "root-session-delete-ingest",
      conversationID: sessionID,
      rootID: "root-session-delete-ingest", kind: .root,
      senderPubkey: creatorPubkey, receiverPubkey: myPubkey,
      ownerPubkey: myPubkey)
    container.mainContext.insert(rootPost)
    container.mainContext.insert(
      try SessionReactionEntity(
        ownerPubkey: myPubkey, sessionID: sessionID,
        postID: rootPost.rootID, emoji: "🔥",
        senderPubkey: peerPubkey, isActive: true,
        eventID: "reaction-session-delete-ingest"))
    container.mainContext.insert(
      try SessionPostDeletionEntity(
        ownerPubkey: myPubkey, sessionID: sessionID,
        rootID: "older-root-watermark",
        deletedByPubkey: creatorPubkey,
        updatedAt: Date(timeIntervalSince1970: 10),
        eventID: "older-root-watermark-event"))
    try container.mainContext.save()

    ingestSessionDelete(
      session,
      IngestOp(id: "session-delete-event", sender: creatorPubkey, time: 1_000, sessionID: sessionID),
      rootID: "op-session-delete")

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchPostDeletions(in: container.mainContext).isEmpty)
    try assertSessionFullyPurged(
      in: container.mainContext, ownerPubkey: myPubkey, sessionID: sessionID)
    let tombstones = try fetchSessionDeletionTombstones(in: container.mainContext)
    XCTAssertEqual(tombstones.count, 1)
    XCTAssertEqual(tombstones.first?.sessionID, sessionID)
    XCTAssertEqual(tombstones.first?.deletedByPubkey, creatorPubkey)
  }

  func testIngestSessionDeleteBeforeSessionSnapshotSuppressesLaterSessionAndRootArrivals() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-before-session-snapshot"
    let rootEventID = "root-pending-until-session-delete-applies"

    ingestSessionDelete(
      session,
      IngestOp(
        id: "session-delete-before-snapshot", sender: creatorPubkey, time: 2_000, sessionID: sessionID
      ),
      rootID: "op-session-delete-before-snapshot",
      source: .historical)
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: creatorPubkey, time: 1_500, sessionID: sessionID),
      url: "https://example.com/session-delete-before-snapshot",
      source: .historical)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(
      try fetchSessionDeletionTombstones(in: container.mainContext).isEmpty)

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-after-pending-delete", sender: creatorPubkey, time: 1_400,
        sessionID: sessionID),
      name: "Pending Deleted Session",
      members: [creatorPubkey, myPubkey], source: .historical)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    try assertSessionFullyPurged(
      in: container.mainContext, ownerPubkey: myPubkey,
      sessionID: sessionID)
    let tombstones = try fetchSessionDeletionTombstones(
      in: container.mainContext)
    XCTAssertEqual(tombstones.count, 1)
    XCTAssertEqual(tombstones.first?.sessionID, sessionID)
    XCTAssertEqual(tombstones.first?.deletedByPubkey, creatorPubkey)
  }

  func testIngestPendingSessionDeleteUsesLatestDeleteEventForTombstoneState() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-pending-tiebreak"
    let tieDate = Date(timeIntervalSince1970: 2_500)

    ingestSessionDelete(
      session,
      IngestOp(id: "session-delete-a", sender: creatorPubkey, time: 2_500, sessionID: sessionID),
      rootID: "op-session-delete-a", source: .historical)
    ingestSessionDelete(
      session,
      IngestOp(id: "session-delete-z", sender: creatorPubkey, time: 2_500, sessionID: sessionID),
      rootID: "op-session-delete-z", source: .historical)

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-after-pending-delete-tiebreak", sender: creatorPubkey, time: 2_400,
        sessionID: sessionID),
      name: "Pending Delete Tiebreak",
      members: [creatorPubkey, myPubkey], source: .historical)

    let tombstone = try XCTUnwrap(
      try fetchSessionDeletionTombstones(in: container.mainContext).first)
    XCTAssertEqual(tombstone.sessionID, sessionID)
    XCTAssertEqual(tombstone.lastEventID, "session-delete-z")
    XCTAssertEqual(tombstone.updatedAt, tieDate)
    XCTAssertEqual(tombstone.deletedByPubkey, creatorPubkey)
    try assertSessionFullyPurged(
      in: container.mainContext, ownerPubkey: myPubkey,
      sessionID: sessionID)
  }

  func testIngestSessionDeleteIgnoresNonCreator() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let otherMemberPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-non-creator-ignored"
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [creatorPubkey, myPubkey, otherMemberPubkey],
      sessionID: sessionID)

    ingestSessionDelete(
      session,
      IngestOp(
        id: "session-delete-non-creator", sender: otherMemberPubkey, time: 1_100, sessionID: sessionID
      ),
      rootID: "op-session-delete-non-creator")

    XCTAssertEqual(
      try container.mainContext.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate {
            $0.ownerPubkey == myPubkey && $0.sessionID == sessionID
          }
        )
      ).count, 1)
    XCTAssertTrue(
      try fetchSessionDeletionTombstones(in: container.mainContext).isEmpty)
  }

  // MARK: - Session rename ingest

  func testIngestSessionMembersRenameAppliesNewName() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-rename-ingest"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-for-rename", sender: creatorPubkey, time: 1000, sessionID: sessionID),
      name: "Original Name", members: [creatorPubkey, myPubkey])

    let before = try XCTUnwrap(
      container.mainContext.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.sessionID == sessionID }
        )
      ).first)
    XCTAssertEqual(before.name, "Original Name")

    ingestSessionMembers(
      session,
      IngestOp(id: "session-members-rename", sender: creatorPubkey, time: 2000, sessionID: sessionID),
      members: [creatorPubkey, myPubkey], name: "Renamed Session")

    let after = try XCTUnwrap(
      container.mainContext.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.sessionID == sessionID }
        )
      ).first)
    XCTAssertEqual(after.name, "Renamed Session")
  }

  func testIngestSessionMembersRenameRespectsEventIDTiebreak() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let winningPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let losingPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-rename-tiebreak"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-for-rename-tiebreak", sender: creatorPubkey, time: 2000,
        sessionID: sessionID),
      name: "Current Name", members: [creatorPubkey, myPubkey])
    ingestSessionMembers(
      session,
      IngestOp(id: "session-members-z", sender: creatorPubkey, time: 2010, sessionID: sessionID),
      members: [creatorPubkey, myPubkey, winningPubkey],
      name: "Winning Rename")
    ingestSessionMembers(
      session,
      IngestOp(id: "session-members-a", sender: creatorPubkey, time: 2010, sessionID: sessionID),
      members: [creatorPubkey, myPubkey, losingPubkey],
      name: "Losing Rename")

    let entity = try XCTUnwrap(
      container.mainContext.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.sessionID == sessionID }
        )
      ).first)
    XCTAssertEqual(entity.name, "Winning Rename")
  }
}
