import SwiftData
import XCTest

@testable import linkstr

// MARK: - Root deletion tests

extension AppSessionIngestTests {

  func testIngestRootDeleteRemovesMatchingStoredPostAndReactions() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete"
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: myPubkey,
      createdByPubkey: senderPubkey,
      memberPubkeys: [myPubkey, senderPubkey], sessionID: sessionID)

    let rootPost = try makeMessage(
      eventID: "root-delete-target", conversationID: sessionID,
      rootID: "root-delete-target", kind: .root,
      senderPubkey: senderPubkey, receiverPubkey: myPubkey,
      ownerPubkey: myPubkey)
    container.mainContext.insert(rootPost)
    container.mainContext.insert(
      try SessionReactionEntity(
        ownerPubkey: myPubkey, sessionID: sessionID,
        postID: rootPost.rootID, emoji: "🔥",
        senderPubkey: myPubkey, isActive: true,
        eventID: "reaction-root-delete-target"))
    try container.mainContext.save()

    ingestRootDelete(
      session,
      IngestOp(id: "root-delete-event", sender: senderPubkey, time: 815, sessionID: sessionID),
      rootID: rootPost.rootID)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.rootID, rootPost.rootID)
    XCTAssertEqual(deletions.first?.deletedByPubkey, senderPubkey)
  }

  func testIngestRootDeleteUsesLatestDeleteEventForTombstoneState() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-tiebreak"
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: myPubkey,
      createdByPubkey: senderPubkey,
      memberPubkeys: [myPubkey, senderPubkey], sessionID: sessionID)

    let rootPost = try makeMessage(
      eventID: "root-delete-tiebreak-target",
      conversationID: sessionID,
      rootID: "root-delete-tiebreak-target", kind: .root,
      senderPubkey: senderPubkey, receiverPubkey: myPubkey,
      ownerPubkey: myPubkey)
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    ingestRootDelete(
      session, IngestOp(id: "root-delete-a", sender: senderPubkey, time: 825, sessionID: sessionID),
      rootID: rootPost.rootID)
    ingestRootDelete(
      session, IngestOp(id: "root-delete-z", sender: senderPubkey, time: 825, sessionID: sessionID),
      rootID: rootPost.rootID)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    let deletion = try XCTUnwrap(
      try fetchPostDeletions(in: container.mainContext).first)
    XCTAssertEqual(deletion.rootID, rootPost.rootID)
    XCTAssertEqual(deletion.deletedByPubkey, senderPubkey)
    XCTAssertEqual(deletion.updatedAt, Date(timeIntervalSince1970: 825))
    XCTAssertEqual(deletion.lastEventID, "root-delete-z")
  }

  func testIngestRootDeleteBeforeRootPostPreventsLaterInsert() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-precedes-post"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-root-delete-precedes-post", sender: senderPubkey, time: 1_400,
        sessionID: sessionID),
      name: "Delete Precedes Post",
      members: [senderPubkey, myPubkey], source: .historical)
    ingestRootDelete(
      session,
      IngestOp(id: "root-delete-preseed", sender: senderPubkey, time: 1_500, sessionID: sessionID),
      rootID: "root-preseed",
      source: .historical)
    ingestRoot(
      session, IngestOp(id: "root-preseed", sender: senderPubkey, time: 1_450, sessionID: sessionID),
      url: "https://example.com/preseed", source: .historical)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.rootID, "root-preseed")
  }

  func testIngestRootDeleteBeforeSessionSnapshotSuppressesRootAfterDependenciesArrive() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-before-session-snapshot"
    let rootEventID = "root-pending-until-session-create"

    ingestRootDelete(
      session,
      IngestOp(
        id: "root-delete-before-session-snapshot", sender: senderPubkey, time: 2_010,
        sessionID: sessionID),
      rootID: rootEventID, source: .historical)
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: senderPubkey, time: 2_000, sessionID: sessionID),
      url: "https://example.com/root-pending-until-session-create",
      source: .historical)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(
      try fetchPostDeletions(in: container.mainContext).isEmpty)

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-after-pending-delete-and-root", sender: senderPubkey, time: 1_990,
        sessionID: sessionID),
      name: "Pending Delete Session",
      members: [senderPubkey, myPubkey], source: .historical)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.rootID, rootEventID)
    XCTAssertEqual(deletions.first?.deletedByPubkey, senderPubkey)
  }

  func testIngestRootDeleteBeforeRootArrivesDiscardsPendingReaction() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-discards-pending-reaction"
    let rootEventID = "root-deleted-before-arrival"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-root-delete-discards-pending-reaction", sender: creatorPubkey,
        time: 1_520, sessionID: sessionID),
      name: "Delete Discards Pending Reaction",
      members: [creatorPubkey, myPubkey, peerPubkey])
    ingestReaction(
      session,
      IngestOp(
        id: "reaction-pending-before-delete", sender: peerPubkey, time: 1_530, sessionID: sessionID),
      rootID: rootEventID, emoji: "🔥", source: .historical)
    ingestRootDelete(
      session,
      IngestOp(
        id: "root-delete-before-arrival-discards-reaction", sender: creatorPubkey, time: 1_540,
        sessionID: sessionID),
      rootID: rootEventID, source: .historical)
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: creatorPubkey, time: 1_525, sessionID: sessionID),
      url: "https://example.com/root-deleted-before-arrival",
      source: .historical)

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.rootID, rootEventID)
    XCTAssertEqual(deletions.first?.deletedByPubkey, creatorPubkey)
  }

  func testIngestRootDeleteIgnoresMismatchedSender() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let rootSenderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let differentSenderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-mismatch"
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: myPubkey,
      createdByPubkey: rootSenderPubkey,
      memberPubkeys: [myPubkey, rootSenderPubkey, differentSenderPubkey],
      sessionID: sessionID)

    let rootPost = try makeMessage(
      eventID: "root-mismatch-target", conversationID: sessionID,
      rootID: "root-mismatch-target", kind: .root,
      senderPubkey: rootSenderPubkey, receiverPubkey: myPubkey,
      ownerPubkey: myPubkey)
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    ingestRootDelete(
      session,
      IngestOp(
        id: "root-delete-mismatch", sender: differentSenderPubkey, time: 1_600, sessionID: sessionID),
      rootID: rootPost.rootID)

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.rootID, rootPost.rootID)
    XCTAssertTrue(
      try fetchPostDeletions(in: container.mainContext).isEmpty)
  }

  func testIngestReactionSurvivesMismatchedDeleteWatermarkBeforeRootArrives() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let rootSenderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let mismatchedDeleterPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-mismatched-delete-watermark"
    let rootEventID = "root-survives-mismatched-delete"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-reaction-mismatched-delete-watermark", sender: creatorPubkey, time: 1_700,
        sessionID: sessionID),
      name: "Reaction Mismatched Delete",
      members: [creatorPubkey, myPubkey, rootSenderPubkey, mismatchedDeleterPubkey])
    ingestRootDelete(
      session,
      IngestOp(
        id: "root-delete-mismatched-before-root", sender: mismatchedDeleterPubkey, time: 1_710,
        sessionID: sessionID),
      rootID: rootEventID, source: .historical)
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: rootSenderPubkey, time: 1_705, sessionID: sessionID),
      url: "https://example.com/reaction-mismatched-delete-watermark",
      source: .historical)
    ingestReaction(
      session,
      IngestOp(
        id: "reaction-after-mismatched-delete-watermark", sender: myPubkey, time: 1_715,
        sessionID: sessionID),
      rootID: rootEventID, emoji: "🔥", source: .historical)

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.rootID, rootEventID)
    let reactions = try fetchReactions(in: container.mainContext)
    XCTAssertEqual(reactions.count, 1)
    XCTAssertEqual(reactions.first?.postID, rootEventID)
    XCTAssertEqual(reactions.first?.senderPubkey, myPubkey)
  }

  func testIngestPendingReactionSurvivesMismatchedDeleteBeforeRootArrives() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let rootSenderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let mismatchedDeleterPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-pending-reaction-mismatched-delete"
    let rootEventID = "root-survives-pending-reaction-mismatched-delete"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-pending-reaction-mismatched-delete", sender: creatorPubkey, time: 1_800,
        sessionID: sessionID),
      name: "Pending Reaction Mismatched Delete",
      members: [creatorPubkey, myPubkey, rootSenderPubkey, mismatchedDeleterPubkey])
    ingestReaction(
      session,
      IngestOp(
        id: "reaction-before-root-mismatched-delete", sender: myPubkey, time: 1_815,
        sessionID: sessionID),
      rootID: rootEventID, emoji: "🔥", source: .historical)
    ingestRootDelete(
      session,
      IngestOp(
        id: "root-delete-mismatched-before-root-pending-reaction", sender: mismatchedDeleterPubkey,
        time: 1_810, sessionID: sessionID),
      rootID: rootEventID, source: .historical)
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: rootSenderPubkey, time: 1_805, sessionID: sessionID),
      url: "https://example.com/root-survives-pending-reaction-mismatched-delete",
      source: .historical)

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.rootID, rootEventID)
    let reactions = try fetchReactions(in: container.mainContext)
    XCTAssertEqual(reactions.count, 1)
    XCTAssertEqual(reactions.first?.postID, rootEventID)
    XCTAssertEqual(reactions.first?.senderPubkey, myPubkey)
  }
}
