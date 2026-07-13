import SwiftData
import XCTest

@testable import linkstr

// MARK: - Read state and reaction guard tests

extension AppSessionIngestTests {

  func testInitialHistoricalRestoreIntoEmptyStoreMarksInboundRootsRead() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-initial-historical-read"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-initial-historical-read", sender: creatorPubkey, time: 1900,
        sessionID: sessionID),
      name: "Initial Historical Read",
      members: [creatorPubkey, myPubkey, peerPubkey], source: .historical)
    ingestRoot(
      session,
      IngestOp(
        id: "root-initial-historical-read", sender: peerPubkey, time: 1905, sessionID: sessionID),
      url: "https://example.com/initial-historical-read",
      source: .historical)

    let message = try XCTUnwrap(
      fetchMessages(in: container.mainContext).first)
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

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-post-restore-historical-unread", sender: creatorPubkey, time: 1910,
        sessionID: sessionID),
      name: "Post Restore Historical Unread",
      members: [creatorPubkey, myPubkey, peerPubkey], source: .historical)

    session.finishInitialHistoricalRestore()

    ingestRoot(
      session,
      IngestOp(
        id: "root-post-restore-historical-unread", sender: peerPubkey, time: 1915,
        sessionID: sessionID),
      url: "https://example.com/post-restore-historical-unread",
      source: .historical)

    let message = try XCTUnwrap(
      fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(
      message.eventID, "root-post-restore-historical-unread")
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

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-reaction-read-state", sender: creatorPubkey, time: 1928,
        sessionID: sessionID),
      name: "Reaction Read State",
      members: [creatorPubkey, myPubkey, peerPubkey])
    ingestRoot(
      session, IngestOp(id: rootID, sender: peerPubkey, time: 1929, sessionID: sessionID),
      url: "https://example.com/reaction-read-state")

    let root = try XCTUnwrap(
      fetchMessages(in: container.mainContext).first)
    root.readAt = expectedReadAt
    try container.mainContext.save()

    ingestReaction(
      session,
      IngestOp(id: "reaction-read-state", sender: creatorPubkey, time: 1931, sessionID: sessionID),
      rootID: rootID, emoji: "🔥")

    XCTAssertEqual(root.readAt, expectedReadAt)
  }

  func testLiveIncomingRootDuringInitialHistoricalRestoreStillStartsUnread() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-live-during-initial-historical-restore"

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-live-during-initial-historical-restore", sender: creatorPubkey,
        time: 1920, sessionID: sessionID),
      name: "Live During Initial Historical Restore",
      members: [creatorPubkey, myPubkey, peerPubkey], source: .historical)
    ingestRoot(
      session,
      IngestOp(
        id: "root-live-during-initial-historical-restore", sender: peerPubkey, time: 1925,
        sessionID: sessionID),
      url: "https://example.com/live-during-initial-historical-restore")

    let message = try XCTUnwrap(
      fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(
      message.eventID, "root-live-during-initial-historical-restore")
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

    ingestSessionCreate(
      session,
      IngestOp(
        id: "session-create-backdated-reaction-guard", sender: creatorPubkey, time: 1700,
        sessionID: sessionID),
      name: "Backdated Reaction Guard",
      members: [creatorPubkey, myPubkey, peerPubkey])
    ingestRoot(
      session, IngestOp(id: rootEventID, sender: creatorPubkey, time: 1704, sessionID: sessionID),
      url: "https://example.com/backdated-reaction-target")
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-remove-backdated-reaction-peer", sender: creatorPubkey, time: 1710,
        sessionID: sessionID),
      members: [creatorPubkey, myPubkey])
    ingestReaction(
      session,
      IngestOp(
        id: "reaction-backdated-from-removed-peer", sender: peerPubkey, time: 1705,
        sessionID: sessionID),
      rootID: rootEventID)

    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
  }

  func testIngestIgnoresReactionFromInactiveMember() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-membership-guard"

    ingestSessionCreate(
      session,
      IngestOp(id: "session-create-3", sender: creatorPubkey, time: 300, sessionID: sessionID),
      name: "Reaction Guard",
      members: [creatorPubkey, myPubkey, peerPubkey])
    ingestSessionMembers(
      session,
      IngestOp(
        id: "session-members-remove-peer", sender: creatorPubkey, time: 310, sessionID: sessionID),
      members: [creatorPubkey, myPubkey])
    ingestReaction(
      session,
      IngestOp(id: "reaction-from-removed-peer", sender: peerPubkey, time: 320, sessionID: sessionID),
      rootID: "missing-root", emoji: "👀")

    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
  }
}
