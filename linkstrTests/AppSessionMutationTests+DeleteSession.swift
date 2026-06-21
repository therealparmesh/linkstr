import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionMutationTests {
  func testDeleteSessionPurgesLocalSessionDataAndPersistsTombstoneWhenNostrIsDisabled()
    async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-local"
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let (thumbnailURL, cachedMediaURL) = try insertRootPostWithMedia(
      in: container.mainContext,
      eventID: "root-session-delete-local",
      sessionID: sessionID,
      myPubkey: myPubkey,
      peerPubkey: peerPubkey
    )
    container.mainContext.insert(
      try SessionReactionEntity(
        ownerPubkey: myPubkey,
        sessionID: sessionID,
        postID: "root-session-delete-local",
        emoji: "🔥",
        senderPubkey: peerPubkey,
        isActive: true,
        eventID: "reaction-session-delete-local"
      )
    )
    container.mainContext.insert(
      try SessionPostDeletionEntity(
        ownerPubkey: myPubkey,
        sessionID: sessionID,
        rootID: "older-root-delete-watermark",
        deletedByPubkey: myPubkey,
        updatedAt: Date(timeIntervalSince1970: 10),
        eventID: "root-delete-watermark"
      )
    )
    try container.mainContext.save()

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMediaURL.path))

    let didDelete = await session.deleteSessionAwaitingRelay(sessionEntity)

    XCTAssertTrue(didDelete)
    assertSessionFullyPurged(
      in: container.mainContext, ownerPubkey: myPubkey, sessionID: sessionID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedMediaURL.path))
  }

  func testDeleteSessionAwaitingRelayBroadcastsDeleteAndRelayDeletionToKnownFormerMembers()
    async throws {
    var capturedRecipients: [String] = []
    var capturedPayload: LinkstrPayload?
    var publishedDeletionEvent: NostrEvent?
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { event in
        publishedDeletionEvent = event
        return "session-kind5-delete"
      },
      sendPayload: { payload, recipients in
        capturedPayload = payload
        capturedRecipients = recipients
        return SentPayloadReceipt(
          rumorEventID: "session-delete-rumor",
          publishedEventIDs: ["session-delete-wrapper"]
        )
      }
    )
    let sessionID = "session-delete-fanout"
    let (fixture, sessionEntity) = try setUpDeleteSessionFixtureWithPost(
      session: session, container: container, sessionID: sessionID,
      rootEventID: "root-session-delete-fanout",
      publishedTransportEventIDs: ["giftwrap-session-root-a", "giftwrap-session-root-b"]
    )

    let didDelete = await session.deleteSessionAwaitingRelay(
      sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didDelete)
    XCTAssertEqual(capturedPayload?.kind, .sessionDelete)
    XCTAssertEqual(capturedPayload?.conversationID, sessionID)
    XCTAssertEqual(
      Set(capturedRecipients),
      Set([fixture.myPubkey, fixture.activePeerPubkey, fixture.formerPeerPubkey])
    )
    let deletionEvent = try XCTUnwrap(publishedDeletionEvent)
    assertDeletionEventCoversTransportIDs(
      deletionEvent,
      expectedIDs: ["giftwrap-session-root-a", "giftwrap-session-root-b"]
    )
    try assertSessionEntityDeleted(
      in: container.mainContext, ownerPubkey: fixture.myPubkey, sessionID: sessionID)
    XCTAssertNil(session.composeError)
  }

  func testDeleteSessionAwaitingRelayWarnsWhenRelaySideDeletionIsUnavailable() async throws {
    var didPublishDeletionEvent = false
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { _ in
        didPublishDeletionEvent = true
        return "unexpected-session-kind5-delete"
      },
      sendPayload: { payload, _ in
        XCTAssertEqual(payload.kind, .sessionDelete)
        return SentPayloadReceipt(
          rumorEventID: "session-delete-rumor-no-kind5",
          publishedEventIDs: ["session-delete-wrapper"]
        )
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-no-kind5"
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )
    let rootPost = try makeMessage(
      eventID: "root-session-delete-no-kind5",
      conversationID: sessionID,
      rootID: "root-session-delete-no-kind5",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deleteSessionAwaitingRelay(
      sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didDelete)
    XCTAssertFalse(didPublishDeletionEvent)
    XCTAssertEqual(
      session.composeError,
      "session deleted, but older relay copies of its posts may remain."
    )
    XCTAssertEqual(try fetchSessionDeletionTombstones(in: container.mainContext).count, 1)
  }

  func testDeleteSessionAwaitingRelayWithoutPostsDoesNotShowRelayLeftoverWarning() async throws {
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { _ in
        XCTFail("unexpected relay deletion publish")
        return "unexpected-session-kind5-delete"
      },
      sendPayload: { payload, _ in
        XCTAssertEqual(payload.kind, .sessionDelete)
        return SentPayloadReceipt(
          rumorEventID: "session-delete-empty-session",
          publishedEventIDs: ["session-delete-wrapper"]
        )
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: "session-delete-empty"
    )

    let didDelete = await session.deleteSessionAwaitingRelay(
      sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didDelete)
    XCTAssertNil(session.composeError)
    XCTAssertEqual(try fetchSessionDeletionTombstones(in: container.mainContext).count, 1)
  }

  // MARK: - Delete Session Helpers

  func insertRootPostWithMedia(
    in context: ModelContext,
    eventID: String,
    sessionID: String,
    myPubkey: String,
    peerPubkey: String
  ) throws -> (thumbnailURL: URL, cachedMediaURL: URL) {
    let thumbnailURL = makeManagedThumbnailURL()
    let cachedMediaURL = makeManagedVideoURL()
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    try Data("media".utf8).write(to: cachedMediaURL, options: .atomic)

    let rootPost = try makeMessage(
      eventID: eventID,
      conversationID: sessionID,
      rootID: eventID,
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    try rootPost.setMetadata(title: "delete session", thumbnailURL: thumbnailURL.path)
    rootPost.cachedMediaPath = cachedMediaURL.path
    rootPost.cachedMediaSourceURL = "https://example.com/video.mp4"
    context.insert(rootPost)
    try context.save()
    return (thumbnailURL, cachedMediaURL)
  }

  func assertSessionFullyPurged(in context: ModelContext, ownerPubkey: String, sessionID: String) {
    XCTAssertTrue((try? fetchMessages(in: context).isEmpty) ?? false)
    XCTAssertTrue(
      (try? context.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
        )
      ).isEmpty) ?? false
    )
    XCTAssertTrue(
      (try? context.fetch(
        FetchDescriptor<SessionMemberEntity>(
          predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
        )
      ).isEmpty) ?? false
    )
    XCTAssertTrue(
      (try? context.fetch(
        FetchDescriptor<SessionMemberIntervalEntity>(
          predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
        )
      ).isEmpty) ?? false
    )
    XCTAssertTrue((try? fetchReactions(in: context).isEmpty) ?? false)
    XCTAssertTrue((try? fetchPostDeletions(in: context).isEmpty) ?? false)
    let tombstones = (try? fetchSessionDeletionTombstones(in: context)) ?? []
    XCTAssertEqual(tombstones.count, 1)
    XCTAssertEqual(tombstones.first?.sessionID, sessionID)
    XCTAssertEqual(tombstones.first?.deletedByPubkey, ownerPubkey)
  }

  func setUpDeleteSessionFixtureWithPost(
    session: AppSession,
    container: ModelContainer,
    sessionID: String,
    rootEventID: String,
    publishedTransportEventIDs: [String]
  ) throws -> (FormerMemberFixture, SessionEntity) {
    let fixture = try setUpSessionWithFormerMember(
      session: session, container: container, sessionID: sessionID)
    let sessionEntity = try XCTUnwrap(
      container.mainContext.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.sessionID == sessionID }
        )
      ).first
    )
    let rootPost = try makeMessage(
      eventID: rootEventID,
      conversationID: sessionID,
      rootID: rootEventID,
      kind: .root,
      senderPubkey: fixture.myPubkey,
      receiverPubkey: fixture.activePeerPubkey,
      ownerPubkey: fixture.myPubkey,
      publishedTransportEventIDs: publishedTransportEventIDs
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()
    return (fixture, sessionEntity)
  }

  func assertSessionEntityDeleted(
    in context: ModelContext,
    ownerPubkey: String,
    sessionID: String
  ) throws {
    XCTAssertTrue(
      try context.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
        )
      ).isEmpty
    )
    XCTAssertEqual(try fetchSessionDeletionTombstones(in: context).count, 1)
  }
}
