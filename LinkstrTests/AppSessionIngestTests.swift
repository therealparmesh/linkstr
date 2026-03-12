import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

@MainActor
final class AppSessionIngestTests: AppSessionTestCase {
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
      testingOverrides: {
        var overrides = AppSession.TestingOverrides()
        overrides.skipNostrNetworkStartup = true
        return overrides
      }()
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
      receiverPubkey: myPubkey,
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
}
