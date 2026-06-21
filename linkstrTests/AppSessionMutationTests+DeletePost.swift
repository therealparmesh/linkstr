import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionMutationTests {
  func testDeletePostClearsLocalRootReactionsAndPersistsDeletionWatermarkWhenNostrIsDisabled()
    async throws {
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
      url: "https://example.com/delete-me",
      note: "bye",
      session: sessionEntity
    )
    XCTAssertTrue(didCreate)

    let rootPost = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    let reaction = try SessionReactionEntity(
      ownerPubkey: myPubkey,
      sessionID: sessionEntity.sessionID,
      postID: rootPost.rootID,
      emoji: "🔥",
      senderPubkey: peerPubkey,
      isActive: true,
      eventID: "reaction-delete-root"
    )
    container.mainContext.insert(reaction)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(rootPost)

    XCTAssertTrue(didDelete)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    let deletions = try fetchPostDeletions(in: container.mainContext)
    XCTAssertEqual(deletions.count, 1)
    XCTAssertEqual(deletions.first?.sessionID, sessionEntity.sessionID)
    XCTAssertEqual(deletions.first?.rootID, rootPost.rootID)
    XCTAssertEqual(deletions.first?.deletedByPubkey, myPubkey)
  }

  func testDeletePostAwaitingRelayUsesStoredGiftWrapIDsAndBroadcastsToKnownFormerMembers()
    async throws {
    var capturedRecipients: [String] = []
    var publishedDeletionEvent: NostrEvent?
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { event in
        publishedDeletionEvent = event
        return "kind5-delete-event"
      },
      sendPayload: { payload, recipients in
        XCTAssertEqual(payload.kind, .rootDelete)
        capturedRecipients = recipients
        return SentPayloadReceipt(
          rumorEventID: "giftwrap-delete-event",
          publishedEventIDs: ["giftwrap-delete-wrapper"]
        )
      }
    )
    let fixture = try setUpSessionWithFormerMember(
      session: session,
      container: container,
      sessionID: "session-delete-fanout"
    )

    let rootPost = try makeMessage(
      eventID: "root-delete-fanout",
      conversationID: "session-delete-fanout",
      rootID: "root-delete-fanout",
      kind: .root,
      senderPubkey: fixture.myPubkey,
      receiverPubkey: fixture.activePeerPubkey,
      ownerPubkey: fixture.myPubkey,
      publishedTransportEventIDs: ["giftwrap-root-delete-a", "giftwrap-root-delete-b"]
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(
      rootPost,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didDelete)
    let deletionEvent = try XCTUnwrap(publishedDeletionEvent)
    assertDeletionEventCoversTransportIDs(
      deletionEvent,
      expectedIDs: ["giftwrap-root-delete-a", "giftwrap-root-delete-b"]
    )
    XCTAssertEqual(Set(capturedRecipients), Set([fixture.myPubkey, fixture.activePeerPubkey, fixture.formerPeerPubkey]))
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertEqual(try fetchPostDeletions(in: container.mainContext).count, 1)
  }

  func testDeletePostRemovesStoredThumbnailAndCachedMediaFiles() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-files"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let thumbnailURL = makeManagedThumbnailURL()
    let cachedMediaURL = makeManagedVideoURL()
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    try Data("media".utf8).write(to: cachedMediaURL, options: .atomic)

    let rootPost = try makeMessage(
      eventID: "root-delete-files",
      conversationID: sessionID,
      rootID: "root-delete-files",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    try rootPost.setMetadata(title: "delete files", thumbnailURL: thumbnailURL.path)
    rootPost.cachedMediaPath = cachedMediaURL.path
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMediaURL.path))

    let didDelete = await session.deletePostAwaitingRelay(rootPost)

    XCTAssertTrue(didDelete)
    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedMediaURL.path))
  }

  func testDeletePostDoesNotRemoveUnmanagedLocalFiles() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-unmanaged-files"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let thumbnailURL = makeUnmanagedTempURL(prefix: "linkstr-delete-thumb", fileExtension: "png")
    let cachedMediaURL = makeUnmanagedTempURL(prefix: "linkstr-delete-media", fileExtension: "mp4")
    defer {
      try? FileManager.default.removeItem(at: thumbnailURL)
      try? FileManager.default.removeItem(at: cachedMediaURL)
    }
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    try Data("media".utf8).write(to: cachedMediaURL, options: .atomic)

    let rootPost = try makeMessage(
      eventID: "root-delete-unmanaged-files",
      conversationID: sessionID,
      rootID: "root-delete-unmanaged-files",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    try rootPost.setMetadata(title: "delete unmanaged files", thumbnailURL: thumbnailURL.path)
    rootPost.cachedMediaPath = cachedMediaURL.path
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(rootPost)

    XCTAssertTrue(didDelete)
    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMediaURL.path))
  }

  func testDeletePostAwaitingRelayWarnsWhenPublishedTransportIDsAreUnavailable() async throws {
    var didPublishDeletionEvent = false
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { _ in
        didPublishDeletionEvent = true
        return "unexpected-kind5-delete"
      },
      sendPayload: { payload, _ in
        XCTAssertEqual(payload.kind, .rootDelete)
        return SentPayloadReceipt(
          rumorEventID: "root-delete-watermark",
          publishedEventIDs: ["root-delete-wrapper"]
        )
      }
    )
    let (myPubkey, peerPubkey) = try setUpSessionWithIdentity(
      session: session,
      container: container,
      sessionID: "session-delete-legacy-root"
    )

    let rootPost = try makeMessage(
      eventID: "legacy-root-delete",
      conversationID: "session-delete-legacy-root",
      rootID: "legacy-root-delete",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: peerPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(
      rootPost,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didDelete)
    XCTAssertFalse(didPublishDeletionEvent)
    XCTAssertEqual(
      session.composeError,
      "post deleted, but relay deletion is unavailable for older copies of this post."
    )
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertEqual(try fetchPostDeletions(in: container.mainContext).count, 1)
  }

  // MARK: - Delete Post Helpers

  func setUpSessionWithIdentity(
    session: AppSession,
    container: ModelContainer,
    sessionID: String
  ) throws -> (myPubkey: String, peerPubkey: String) {
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )
    return (myPubkey, peerPubkey)
  }

  struct FormerMemberFixture {
    let myPubkey: String
    let activePeerPubkey: String
    let formerPeerPubkey: String
  }

  func setUpSessionWithFormerMember(
    session: AppSession,
    container: ModelContainer,
    sessionID: String
  ) throws -> FormerMemberFixture {
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let activePeerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let formerPeerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, activePeerPubkey, formerPeerPubkey],
      sessionID: sessionID
    )

    let formerMember = try XCTUnwrap(
      container.mainContext.fetch(
        FetchDescriptor<SessionMemberEntity>(
          predicate: #Predicate {
            $0.ownerPubkey == myPubkey
              && $0.sessionID == sessionID
              && $0.isActive == true
          }
        )
      ).first(where: { $0.memberPubkey == formerPeerPubkey })
    )
    formerMember.isActive = false
    try container.mainContext.save()
    return FormerMemberFixture(
      myPubkey: myPubkey,
      activePeerPubkey: activePeerPubkey,
      formerPeerPubkey: formerPeerPubkey
    )
  }

  func assertDeletionEventCoversTransportIDs(
    _ event: NostrEvent,
    expectedIDs: [String]
  ) {
    XCTAssertEqual(event.kind.rawValue, EventKind.deletion.rawValue)
    XCTAssertEqual(
      Set(event.tags.filter { $0.name == "e" }.map(\.value)),
      Set(expectedIDs)
    )
    XCTAssertEqual(
      event.tags.filter { $0.name == "k" }.map(\.value),
      [String(EventKind.giftWrap.rawValue)]
    )
  }
}
