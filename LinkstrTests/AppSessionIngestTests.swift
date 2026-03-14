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

  func testLiveRootAfterReaddWaitsForOutOfOrderMembershipSnapshot() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-live-readd-ordering"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-live-readd-ordering",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1000),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1000,
          sessionName: "Live Readd Ordering",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-remove-live-readd-ordering",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1010),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-remove",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 1010,
          memberPubkeys: [creatorPubkey, peerPubkey]
        )
      ))

    let readdDate = Date(timeIntervalSince1970: 1020)
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-after-readd-before-membership-update",
        senderPubkey: peerPubkey,
        createdAt: readdDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-after-readd-before-membership-update",
          kind: .root,
          url: "https://example.com/root-after-readd-before-membership-update",
          note: nil,
          timestamp: 1020
        )
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-readd-live-readd-ordering",
        senderPubkey: creatorPubkey,
        createdAt: readdDate,
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-readd",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 1020,
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.map(\.eventID), ["root-after-readd-before-membership-update"])
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

  func testInitialHistoricalRestoreIntoEmptyStoreMarksInboundRootsRead() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-initial-historical-read"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-initial-historical-read",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1900),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1900,
          sessionName: "Initial Historical Read",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-initial-historical-read",
        senderPubkey: peerPubkey,
        createdAt: Date(timeIntervalSince1970: 1905),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-initial-historical-read",
          kind: .root,
          url: "https://example.com/initial-historical-read",
          note: nil,
          timestamp: 1905
        ),
        source: .historical
      ))

    let message = try XCTUnwrap(fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(message.eventID, "root-initial-historical-read")
    XCTAssertNotNil(message.readAt)
  }

  func testHistoricalReplayAfterInitialRestoreCompletionLeavesInboundRootsUnread() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    session.startNostrIfPossible()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-post-restore-historical-unread"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-post-restore-historical-unread",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1910),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1910,
          sessionName: "Post Restore Historical Unread",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        ),
        source: .historical
      ))

    session.simulateInitialHistoricalRestoreCompletionForTesting()

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-post-restore-historical-unread",
        senderPubkey: peerPubkey,
        createdAt: Date(timeIntervalSince1970: 1915),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-post-restore-historical-unread",
          kind: .root,
          url: "https://example.com/post-restore-historical-unread",
          note: nil,
          timestamp: 1915
        ),
        source: .historical
      ))

    let message = try XCTUnwrap(fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(message.eventID, "root-post-restore-historical-unread")
    XCTAssertNil(message.readAt)
  }

  func testIngestReactionDoesNotAffectRootReadState() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-read-state"
    let rootID = "root-reaction-read-state"
    let expectedReadAt = Date(timeIntervalSince1970: 1930)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-reaction-read-state",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1928),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1928,
          sessionName: "Reaction Read State",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootID,
        senderPubkey: peerPubkey,
        createdAt: Date(timeIntervalSince1970: 1929),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootID,
          kind: .root,
          url: "https://example.com/reaction-read-state",
          note: nil,
          timestamp: 1929
        )
      ))

    let root = try XCTUnwrap(fetchMessages(in: container.mainContext).first)
    root.readAt = expectedReadAt
    try container.mainContext.save()

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-read-state",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1931),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 1931,
          emoji: "🔥",
          reactionActive: true
        )
      ))

    XCTAssertEqual(root.readAt, expectedReadAt)
  }

  func testLiveIncomingRootDuringInitialHistoricalRestoreStillStartsUnread() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-live-during-initial-historical-restore"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-live-during-initial-historical-restore",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1920),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1920,
          sessionName: "Live During Initial Historical Restore",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-live-during-initial-historical-restore",
        senderPubkey: peerPubkey,
        createdAt: Date(timeIntervalSince1970: 1925),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-live-during-initial-historical-restore",
          kind: .root,
          url: "https://example.com/live-during-initial-historical-restore",
          note: nil,
          timestamp: 1925
        )
      ))

    let message = try XCTUnwrap(fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(message.eventID, "root-live-during-initial-historical-restore")
    XCTAssertNil(message.readAt)
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

  func testIngestQueuesRootUntilSessionCreateArrives() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-pending-root-create"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-before-session-create",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 905),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-before-session-create",
          kind: .root,
          url: "https://example.com/root-before-session-create",
          note: "arrived first",
          timestamp: 905
        )
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SessionEntity>()).isEmpty)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-after-root-arrival",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 900),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 900,
          sessionName: "Pending Root Session",
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    let sessions = try container.mainContext.fetch(FetchDescriptor<SessionEntity>())
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.name, "Pending Root Session")
    XCTAssertEqual(
      try fetchMessages(in: container.mainContext).map(\.eventID), ["root-before-session-create"])
  }

  func testIngestSessionMembersBootstrapsMissingSessionAndReplaysPendingRoot() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-bootstrap-from-members"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-before-bootstrap-snapshot",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1005),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "root-before-bootstrap-snapshot",
          kind: .root,
          url: "https://example.com/root-before-bootstrap",
          note: "late add root",
          timestamp: 1005
        )
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-members-bootstrap",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1000),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-add",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: 1000,
          sessionName: "Late Add Session",
          memberPubkeys: [creatorPubkey, myPubkey]
        )
      ))

    let sessionEntity = try XCTUnwrap(
      container.mainContext.fetch(FetchDescriptor<SessionEntity>()).first
    )
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

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-pending-reaction",
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
        eventID: "reaction-before-root",
        senderPubkey: peerPubkey,
        createdAt: Date(timeIntervalSince1970: 810),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 810,
          emoji: "👍",
          reactionActive: true
        )
      ))

    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 805),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/root-arrives-after-reaction",
          note: nil,
          timestamp: 805
        )
      ))

    let reactions = try fetchReactions(in: container.mainContext)
    XCTAssertEqual(reactions.count, 1)
    let reaction = try XCTUnwrap(reactions.first)
    XCTAssertEqual(reaction.postID, rootEventID)
    XCTAssertEqual(reaction.senderPubkey, peerPubkey)
    XCTAssertTrue(reaction.isActive)
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

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-root-delete-precedes-post",
        senderPubkey: senderPubkey,
        createdAt: Date(timeIntervalSince1970: 1_400),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1_400,
          sessionName: "Delete Precedes Post",
          memberPubkeys: [senderPubkey, myPubkey]
        ),
        source: .historical
      ))

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

  func testIngestRootDeleteBeforeSessionSnapshotSuppressesRootAfterDependenciesArrive() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-root-delete-before-session-snapshot"
    let rootEventID = "root-pending-until-session-create"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-delete-before-session-snapshot",
        senderPubkey: senderPubkey,
        createdAt: Date(timeIntervalSince1970: 2_010),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: 2_010
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        senderPubkey: senderPubkey,
        createdAt: Date(timeIntervalSince1970: 2_000),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/root-pending-until-session-create",
          note: nil,
          timestamp: 2_000
        ),
        source: .historical
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchPostDeletions(in: container.mainContext).isEmpty)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-after-pending-delete-and-root",
        senderPubkey: senderPubkey,
        createdAt: Date(timeIntervalSince1970: 1_990),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1_990,
          sessionName: "Pending Delete Session",
          memberPubkeys: [senderPubkey, myPubkey]
        ),
        source: .historical
      ))

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

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-root-delete-discards-pending-reaction",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1_520),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1_520,
          sessionName: "Delete Discards Pending Reaction",
          memberPubkeys: [creatorPubkey, myPubkey, peerPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-pending-before-delete",
        senderPubkey: peerPubkey,
        createdAt: Date(timeIntervalSince1970: 1_530),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 1_530,
          emoji: "🔥",
          reactionActive: true
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-delete-before-arrival-discards-reaction",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1_540),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: 1_540
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1_525),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/root-deleted-before-arrival",
          note: nil,
          timestamp: 1_525
        ),
        source: .historical
      ))

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

  func testIngestReactionSurvivesMismatchedDeleteWatermarkBeforeRootArrives() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let rootSenderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let mismatchedDeleterPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-mismatched-delete-watermark"
    let rootEventID = "root-survives-mismatched-delete"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-reaction-mismatched-delete-watermark",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1_700),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1_700,
          sessionName: "Reaction Mismatched Delete",
          memberPubkeys: [creatorPubkey, myPubkey, rootSenderPubkey, mismatchedDeleterPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-delete-mismatched-before-root",
        senderPubkey: mismatchedDeleterPubkey,
        createdAt: Date(timeIntervalSince1970: 1_710),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: 1_710
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        senderPubkey: rootSenderPubkey,
        createdAt: Date(timeIntervalSince1970: 1_705),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/reaction-mismatched-delete-watermark",
          note: nil,
          timestamp: 1_705
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-after-mismatched-delete-watermark",
        senderPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1_715),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 1_715,
          emoji: "🔥",
          reactionActive: true
        ),
        source: .historical
      ))

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

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-pending-reaction-mismatched-delete",
        senderPubkey: creatorPubkey,
        createdAt: Date(timeIntervalSince1970: 1_800),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 1_800,
          sessionName: "Pending Reaction Mismatched Delete",
          memberPubkeys: [creatorPubkey, myPubkey, rootSenderPubkey, mismatchedDeleterPubkey]
        )
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "reaction-before-root-mismatched-delete",
        senderPubkey: myPubkey,
        createdAt: Date(timeIntervalSince1970: 1_815),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: 1_815,
          emoji: "🔥",
          reactionActive: true
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "root-delete-mismatched-before-root-pending-reaction",
        senderPubkey: mismatchedDeleterPubkey,
        createdAt: Date(timeIntervalSince1970: 1_810),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: 1_810
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        senderPubkey: rootSenderPubkey,
        createdAt: Date(timeIntervalSince1970: 1_805),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/root-survives-pending-reaction-mismatched-delete",
          note: nil,
          timestamp: 1_805
        ),
        source: .historical
      ))

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.rootID, rootEventID)

    let reactions = try fetchReactions(in: container.mainContext)
    XCTAssertEqual(reactions.count, 1)
    XCTAssertEqual(reactions.first?.postID, rootEventID)
    XCTAssertEqual(reactions.first?.senderPubkey, myPubkey)
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

  func testPendingRootMergesTransportEventIDsAcrossDuplicateWrappers() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let senderPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-pending-root-merge-wrappers"
    let rootEventID = "root-pending-merge-wrapper"

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        transportEventID: "giftwrap-pending-root-a",
        senderPubkey: senderPubkey,
        createdAt: Date(timeIntervalSince1970: 2_200),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/root-pending-merge-wrapper",
          note: nil,
          timestamp: 2_200
        ),
        source: .historical
      ))

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: rootEventID,
        transportEventID: "giftwrap-pending-root-b",
        senderPubkey: senderPubkey,
        createdAt: Date(timeIntervalSince1970: 2_200),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: rootEventID,
          kind: .root,
          url: "https://example.com/root-pending-merge-wrapper",
          note: nil,
          timestamp: 2_200
        ),
        source: .historical
      ))

    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)

    session.ingestForTesting(
      makeIncomingMessage(
        eventID: "session-create-after-pending-root-wrapper-merge",
        senderPubkey: senderPubkey,
        createdAt: Date(timeIntervalSince1970: 2_190),
        payload: LinkstrPayload(
          conversationID: sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: 2_190,
          sessionName: "Pending Root Wrapper Merge",
          memberPubkeys: [senderPubkey, myPubkey]
        ),
        source: .historical
      ))

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(
      Set(try XCTUnwrap(messages.first).publishedTransportEventIDs),
      Set(["giftwrap-pending-root-a", "giftwrap-pending-root-b"])
    )
  }
}
