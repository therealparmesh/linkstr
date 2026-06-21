import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionMutationTests {
  func testCreateSessionPostRejectsInvalidURL() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "not-a-url",
      note: nil,
      session: sessionEntity
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "enter a valid url.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testUpdateSessionMembersAwaitingRelayRequiresSessionCreator() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-creator-guard"
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [myPubkey, creatorPubkey, peerPubkey],
      sessionID: sessionID
    )
    let peerNPub = try XCTUnwrap(PublicKey(hex: peerPubkey)?.npub)

    let didUpdate = await session.updateSessionMembersAwaitingRelay(
      session: sessionEntity,
      memberNPubs: [peerNPub]
    )

    XCTAssertFalse(didUpdate)
    XCTAssertEqual(session.composeError, "only the session creator can manage this session.")

    let members = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(Set(members.map(\.memberPubkey)), Set([myPubkey, creatorPubkey, peerPubkey]))
  }

  func testUpdateSessionMembersAwaitingRelayBroadcastsToPriorAndNextMembers() async throws {
    var capturedRecipients: [String] = []
    var capturedPayload: LinkstrPayload?
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { payload, recipients in
        capturedPayload = payload
        capturedRecipients = recipients
        return SentPayloadReceipt(
          rumorEventID: "session-members-event",
          publishedEventIDs: ["session-members-wrapper"]
        )
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let priorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let removedPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let addedPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let priorNPub = try XCTUnwrap(PublicKey(hex: priorPubkey)?.npub)
    let addedNPub = try XCTUnwrap(PublicKey(hex: addedPubkey)?.npub)
    let sessionID = "session-broadcast-fanout"

    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, priorPubkey, removedPubkey],
      sessionID: sessionID
    )

    let didUpdate = await session.updateSessionMembersAwaitingRelay(
      session: sessionEntity,
      memberNPubs: [priorNPub, addedNPub]
    )

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(
      Set(capturedRecipients),
      Set([myPubkey, priorPubkey, removedPubkey, addedPubkey])
    )
    XCTAssertEqual(capturedPayload?.kind, .sessionMembers)
    XCTAssertEqual(capturedPayload?.sessionName, sessionEntity.name)

    let activeMembers = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(
      Set(activeMembers.map(\.memberPubkey)), Set([myPubkey, priorPubkey, addedPubkey]))
  }

  func testCreateSessionPostAwaitingRelayRequiresActiveSessionMembership() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [creatorPubkey, peerPubkey],
      sessionID: "session-no-membership-send"
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: "hello",
      session: sessionEntity
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "you're no longer a member of this session.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testIsCurrentUserActiveMemberReflectsCurrentSessionMembership() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let activeSession = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: "session-active-membership-helper"
    )
    let removedSession = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: peerPubkey,
      memberPubkeys: [peerPubkey],
      sessionID: "session-removed-membership-helper"
    )

    XCTAssertTrue(session.isCurrentUserActiveMember(of: activeSession))
    XCTAssertFalse(session.isCurrentUserActiveMember(of: removedSession))
    XCTAssertFalse(
      session.isCurrentUserActiveMember(
        sessionID: removedSession.sessionID,
        ownerPubkey: removedSession.ownerPubkey
      )
    )
  }

  func testToggleReactionAwaitingRelayRequiresActiveSessionMembership() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let creatorPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-no-membership-react"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: creatorPubkey,
      memberPubkeys: [creatorPubkey, peerPubkey],
      sessionID: sessionID
    )

    let post = try makeMessage(
      eventID: "react-target",
      conversationID: sessionID,
      rootID: "react-target",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(post)
    try container.mainContext.save()

    let didToggle = await session.toggleReactionAwaitingRelay(emoji: "👍", post: post)

    XCTAssertFalse(didToggle)
    XCTAssertEqual(session.composeError, "you're no longer a member of this session.")
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostAwaitingRelayDoesNotPersistWhenRelayRejectsPublish() async throws {
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { _, _ in
        throw NostrServiceError.publishRejected("blocked: policy")
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "blocked: policy")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  // MARK: - Session rename

  func testRenameSessionPublishesUpdatedNameAndKeepsActiveMembers() async throws {
    var capturedPayload: LinkstrPayload?
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { payload, _ in
        capturedPayload = payload
        return SentPayloadReceipt(
          rumorEventID: "rename-event",
          publishedEventIDs: ["rename-wrapper"]
        )
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let peerNPub = try XCTUnwrap(PublicKey(hex: peerPubkey)?.npub)
    let sessionID = "session-rename-payload"

    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      name: "Original Name",
      sessionID: sessionID
    )

    let didUpdate = await session.updateSessionMembersAwaitingRelay(
      session: sessionEntity,
      memberNPubs: [peerNPub],
      sessionName: "Renamed Session"
    )

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(capturedPayload?.kind, .sessionMembers)
    XCTAssertEqual(capturedPayload?.sessionName, "Renamed Session")

    let activeMembers = try container.mainContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == myPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(Set(activeMembers.map(\.memberPubkey)), Set([myPubkey, peerPubkey]))

    let updated = try XCTUnwrap(
      container.mainContext.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.sessionID == sessionID }
        )
      ).first
    )
    XCTAssertEqual(updated.name, "Renamed Session")
  }
}
