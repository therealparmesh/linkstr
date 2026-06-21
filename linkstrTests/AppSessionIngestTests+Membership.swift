import SwiftData
import XCTest

@testable import linkstr

// MARK: - Membership lifecycle and guard tests

extension AppSessionIngestTests {

  func testIngestMembershipLifecycleHonorsMembershipWindows() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-membership-lifecycle"
    let allMembers = [creatorPubkey, myPubkey, peerPubkey]

    ingestSessionCreate(
      session,
      IngestOp(id: "session-create-1", sender: creatorPubkey, time: 100, sessionID: sessionID),
      name: "Lifecycle Session",
      members: allMembers)
    ingestRoot(
      session,
      IngestOp(id: "root-before-removal", sender: peerPubkey, time: 110, sessionID: sessionID),
      url: "https://example.com/before-removal")
    ingestSessionMembers(
      session,
      IngestOp(id: "session-members-remove", sender: creatorPubkey, time: 120, sessionID: sessionID),
      members: [creatorPubkey, peerPubkey])
    ingestRoot(
      session,
      IngestOp(id: "root-during-removal", sender: peerPubkey, time: 130, sessionID: sessionID),
      url: "https://example.com/during-removal")
    ingestSessionMembers(
      session,
      IngestOp(id: "session-members-readd", sender: creatorPubkey, time: 140, sessionID: sessionID),
      members: allMembers)
    ingestRoot(
      session, IngestOp(id: "root-after-readd", sender: peerPubkey, time: 150, sessionID: sessionID),
      url: "https://example.com/after-readd")
    ingestRoot(
      session,
      IngestOp(
        id: "root-backfill-before-removal", sender: peerPubkey, time: 115, sessionID: sessionID),
      url: "https://example.com/backfill-before")
    ingestRoot(
      session,
      IngestOp(
        id: "root-backfill-during-removal", sender: peerPubkey, time: 135, sessionID: sessionID),
      url: "https://example.com/backfill-during")

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(
      Set(messages.map(\.eventID)),
      Set(["root-before-removal", "root-after-readd", "root-backfill-before-removal"]))
  }

  func testLiveRootAfterReaddWaitsForOutOfOrderMembershipSnapshot() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-live-readd-ordering"
    let allMembers = [creatorPubkey, myPubkey, peerPubkey]

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-live-readd-ordering", sender: creatorPubkey, time: 1000,
        sessionID: sessionID),
      name: "Live Readd Ordering", members: allMembers)
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-remove-live-readd-ordering", sender: creatorPubkey, time: 1010,
        sessionID: sessionID),
      members: [creatorPubkey, peerPubkey])
    ingestRoot(
      session,
      IngestOp(
        id: "root-after-readd-before-membership-update", sender: peerPubkey, time: 1020,
        sessionID: sessionID),
      url: "https://example.com/root-after-readd-before-membership-update")

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)

    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-readd-live-readd-ordering", sender: creatorPubkey, time: 1020,
        sessionID: sessionID),
      members: allMembers)

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(
      messages.map(\.eventID), ["root-after-readd-before-membership-update"])
  }

  func testIngestIgnoresBackdatedRootFromCurrentlyInactiveMember() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-backdated-inactive"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-backdated-root-guard", sender: creatorPubkey, time: 1600,
        sessionID: sessionID),
      name: "Backdated Root Guard", members: [creatorPubkey, myPubkey, peerPubkey])
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-remove-backdated-root-peer", sender: creatorPubkey, time: 1610,
        sessionID: sessionID),
      members: [creatorPubkey, myPubkey])
    ingestRoot(
      session,
      IngestOp(
        id: "root-backdated-from-removed-peer", sender: peerPubkey, time: 1605, sessionID: sessionID),
      url: "https://example.com/backdated-root-removed-peer")

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testIngestAllowsHistoricalRootFromInactiveMemberWhenTimestampWasActive() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let removedPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-historical-root-from-removed-member"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-historical-root-guard", sender: creatorPubkey, time: 1800,
        sessionID: sessionID),
      name: "Historical Root Guard",
      members: [creatorPubkey, myPubkey, removedPubkey])
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-remove-historical-root-peer", sender: creatorPubkey, time: 1810,
        sessionID: sessionID),
      members: [creatorPubkey, myPubkey])
    ingestRoot(
      session,
      IngestOp(
        id: "root-historical-from-removed-peer", sender: removedPubkey, time: 1805,
        sessionID: sessionID),
      url: "https://example.com/historical-root-removed-peer",
      source: .historical)

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(
      messages.map(\.eventID), ["root-historical-from-removed-peer"])
  }

  func testIngestIgnoresNonCreatorMembershipMutations() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let attackerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-non-creator-mutation"

    ingestSessionCreate(
      session,
      IngestOp(id: "session-create-2", sender: creatorPubkey, time: 200, sessionID: sessionID),
      name: "Creator Session",
      members: [creatorPubkey, myPubkey, peerPubkey])
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-attacker", sender: attackerPubkey, time: 210, sessionID: sessionID),
      members: [attackerPubkey, myPubkey])

    try assertActiveMembers(
      in: container.mainContext, ownerPubkey: myPubkey,
      sessionID: sessionID,
      expected: Set([creatorPubkey, myPubkey, peerPubkey]))
  }

  func testIngestSessionCreateRequiresSenderAndReceiverInMemberSnapshot() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-missing-sender", sender: creatorPubkey, time: 400,
        sessionID: "session-create-guard-1"),
      name: "Missing Sender",
      members: [myPubkey, peerPubkey])
    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-missing-receiver", sender: creatorPubkey, time: 410,
        sessionID: "session-create-guard-2"),
      name: "Missing Receiver",
      members: [creatorPubkey, peerPubkey])

    let sessions = try container.mainContext.fetch(
      FetchDescriptor<SessionEntity>())
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

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-membership-guard", sender: creatorPubkey, time: 500, sessionID: sessionID),
      name: "Membership Guard",
      members: [creatorPubkey, myPubkey, removedPubkey])
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-membership-remove", sender: creatorPubkey, time: 600, sessionID: sessionID),
      members: [creatorPubkey, myPubkey])
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-membership-stale-backfill", sender: creatorPubkey, time: 550,
        sessionID: sessionID),
      members: [creatorPubkey, myPubkey, stalePubkey])

    try assertActiveMembers(
      in: container.mainContext, ownerPubkey: myPubkey,
      sessionID: sessionID,
      expected: Set([creatorPubkey, myPubkey]))
  }

  func testMembershipSnapshotUsesEventIDTiebreakForEqualTimestamp() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let winnerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let loserPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-membership-tiebreak"

    ingestSessionCreate(
      session,
      IngestOp(id: "session-create-tiebreak", sender: creatorPubkey, time: 700, sessionID: sessionID),
      name: "Tiebreak", members: [creatorPubkey, myPubkey])
    ingestSessionMembers(
      session,
      IngestOp(id: "session-members-z", sender: creatorPubkey, time: 710, sessionID: sessionID),
      members: [creatorPubkey, myPubkey, winnerPubkey])
    ingestSessionMembers(
      session,
      IngestOp(id: "session-members-a", sender: creatorPubkey, time: 710, sessionID: sessionID),
      members: [creatorPubkey, myPubkey, loserPubkey])

    let activeMembers = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(
      Set(activeMembers.map(\.memberPubkey)),
      Set([creatorPubkey, myPubkey, winnerPubkey]))
    XCTAssertFalse(
      activeMembers.contains(where: { $0.memberPubkey == loserPubkey }))
  }
}
