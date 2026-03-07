import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

@MainActor
final class AppSessionMutationTests: AppSessionTestCase {
  func testCreateSessionPostAwaitingRelayTimesOutWhenRelayNeverConnects() async throws {
    let (session, container) = try makeSession(disableNostrStartup: false)
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com", status: .disconnected))
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "couldn't reconnect to relays in time. try again.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionSetsPendingNavigationID() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let peerNPub = try TestKeyMaterialFactory.makeNPub()

    let didCreate = await session.createSessionAwaitingRelay(
      name: "Navigation Session",
      memberNPubs: [peerNPub]
    )

    XCTAssertTrue(didCreate)
    let sessions = try container.mainContext.fetch(
      FetchDescriptor<SessionEntity>(sortBy: [SortDescriptor(\.createdAt)]))
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(session.pendingSessionNavigationID, sessions.first?.sessionID)

    session.clearPendingSessionNavigationID()
    XCTAssertNil(session.pendingSessionNavigationID)
  }

  func testCreateSessionPostAwaitingRelaySendsWhenLiveRelayConnectionExists() async throws {
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { _, _ in
        SentPayloadReceipt(
          rumorEventID: "await-root-event",
          publishedEventIDs: ["giftwrap-await-root-1", "giftwrap-await-root-2"]
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
      memberPubkeys: [myPubkey, peerPubkey]
    )

    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com", status: .failed))
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didCreate)
    XCTAssertNil(session.composeError)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
  }

  func testCreateSessionPostAwaitingRelayWithReadOnlyRelaysShowsReadOnlyMessage() async throws {
    let (session, container) = try makeSession(disableNostrStartup: false)
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey]
    )

    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com", status: .readOnly))
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError,
      "connected relays are read-only. add a writable relay to send."
    )
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostAwaitingRelayWithNoEnabledRelaysShowsNoEnabledRelaysMessage()
    async throws
  {
    let (session, container) = try makeSession(disableNostrStartup: false)
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
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError, "no relays are enabled. enable at least one relay in settings.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostPersistsOutgoingRootMessage() async throws {
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
      url: "https://example.com/path",
      note: "hello",
      session: sessionEntity
    )

    XCTAssertTrue(didCreate)
    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    let message = try XCTUnwrap(messages.first)
    XCTAssertEqual(message.kind, .root)
    XCTAssertEqual(message.url, "https://example.com/path")
    XCTAssertEqual(message.note, "hello")
    XCTAssertNotEqual(message.encryptedURL, "https://example.com/path")
    XCTAssertNotEqual(message.encryptedNote, "hello")
    XCTAssertNotNil(message.readAt)
    XCTAssertFalse(message.eventID.isEmpty)
    XCTAssertNil(session.composeError)
  }

  func testCreateSessionPostPersistsPublishedTransportEventIDsFromRelayReceipt() async throws {
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { _, _ in
        SentPayloadReceipt(
          rumorEventID: "root-rumor-id",
          publishedEventIDs: ["giftwrap-root-a", "giftwrap-root-b"]
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
      memberPubkeys: [myPubkey, peerPubkey]
    )

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: "hello",
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didCreate)
    let message = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(message.eventID, "root-rumor-id")
    XCTAssertEqual(message.rootID, "root-rumor-id")
    XCTAssertEqual(message.publishedTransportEventIDs, ["giftwrap-root-a", "giftwrap-root-b"])
  }

  func testDeletePostClearsLocalRootReactionsAndPersistsDeletionWatermarkWhenNostrIsDisabled()
    async throws
  {
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
    async throws
  {
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
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let activePeerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let formerPeerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-fanout"
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

    let rootPost = makeMessage(
      eventID: "root-delete-fanout",
      conversationID: sessionID,
      rootID: "root-delete-fanout",
      kind: .root,
      senderPubkey: myPubkey,
      receiverPubkey: activePeerPubkey,
      ownerPubkey: myPubkey,
      publishedTransportEventIDs: ["giftwrap-root-delete-a", "giftwrap-root-delete-b"]
    )
    container.mainContext.insert(rootPost)
    try container.mainContext.save()

    let didDelete = await session.deletePostAwaitingRelay(
      rootPost,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didDelete)
    let deletionEvent = try XCTUnwrap(publishedDeletionEvent)
    XCTAssertEqual(deletionEvent.kind.rawValue, EventKind.deletion.rawValue)
    XCTAssertEqual(
      Set(deletionEvent.tags.filter { $0.name == "e" }.map(\.value)),
      Set(["giftwrap-root-delete-a", "giftwrap-root-delete-b"])
    )
    XCTAssertEqual(
      deletionEvent.tags.filter { $0.name == "k" }.map(\.value),
      [String(EventKind.giftWrap.rawValue)]
    )
    XCTAssertEqual(Set(capturedRecipients), Set([myPubkey, activePeerPubkey, formerPeerPubkey]))
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

    let rootPost = makeMessage(
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

    let rootPost = makeMessage(
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
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-delete-legacy-root"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let rootPost = makeMessage(
      eventID: "legacy-root-delete",
      conversationID: sessionID,
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
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
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
    XCTAssertEqual(session.composeError, "only the session creator can manage members.")

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
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { _, recipients in
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

    let relay = RelayEntity(url: "wss://relay.example.com", status: .connected)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    let didUpdate = await session.updateSessionMembersAwaitingRelay(
      session: sessionEntity,
      memberNPubs: [priorNPub, addedNPub]
    )

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(
      Set(capturedRecipients),
      Set([myPubkey, priorPubkey, removedPubkey, addedPubkey])
    )

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

    let post = makeMessage(
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

    let relay = RelayEntity(url: "wss://relay.example.com", status: .connected)
    container.mainContext.insert(relay)
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "blocked: policy")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }
}
