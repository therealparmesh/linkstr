import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class AppSessionPushTests: AppSessionTestCase {
  func testCreateSessionPostAwaitingRelayEnqueuesNewPostPushAfterRelayAcceptance() async throws {
    var capturedRequests: [PushEnqueueRequest] = []
    let enqueueExpectation = expectation(description: "enqueue new post push")

    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { _, _ in
        SentPayloadReceipt(
          rumorEventID: "await-root-event",
          publishedEventIDs: ["giftwrap-await-root-1"]
        )
      },
      enqueuePushNotification: { request in
        capturedRequests.append(request)
        enqueueExpectation.fulfill()
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
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didCreate)
    await fulfillment(of: [enqueueExpectation], timeout: asyncExpectationTimeoutSeconds)
    XCTAssertEqual(capturedRequests.count, 1)
    XCTAssertEqual(capturedRequests[0].notificationType, "new_post")
    XCTAssertEqual(capturedRequests[0].eventID, "await-root-event")
    XCTAssertEqual(capturedRequests[0].conversationID, sessionEntity.sessionID)
    XCTAssertEqual(Set(capturedRequests[0].recipientPubkeys), Set([myPubkey, peerPubkey]))
    XCTAssertNil(capturedRequests[0].emoji)
  }

  func testToggleReactionAwaitingRelayEnqueuesOnlyActiveReactionPush() async throws {
    var capturedRequests: [PushEnqueueRequest] = []
    let enqueueExpectation = expectation(description: "enqueue new reaction push")

    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { payload, _ in
        let rumorEventID = payload.reactionActive == true ? "reaction-on" : "reaction-off"
        return SentPayloadReceipt(rumorEventID: rumorEventID, publishedEventIDs: [])
      },
      enqueuePushNotification: { request in
        capturedRequests.append(request)
        enqueueExpectation.fulfill()
      }
    )

    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let peerPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let sessionID = "session-reaction-push"
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey, peerPubkey],
      sessionID: sessionID
    )

    let post = try makeMessage(
      eventID: "root-reaction-target",
      conversationID: sessionID,
      rootID: "root-reaction-target",
      kind: .root,
      senderPubkey: peerPubkey,
      receiverPubkey: myPubkey,
      ownerPubkey: myPubkey
    )
    container.mainContext.insert(post)
    let didActivate = await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post)

    XCTAssertTrue(didActivate)
    await fulfillment(of: [enqueueExpectation], timeout: asyncExpectationTimeoutSeconds)
    XCTAssertEqual(capturedRequests.count, 1)
    XCTAssertEqual(capturedRequests[0].notificationType, "new_emoji_reaction")
    XCTAssertEqual(capturedRequests[0].eventID, "reaction-on")
    XCTAssertEqual(capturedRequests[0].conversationID, sessionID)
    XCTAssertEqual(Set(capturedRequests[0].recipientPubkeys), Set([myPubkey, peerPubkey]))
    XCTAssertEqual(capturedRequests[0].emoji, "🔥")
    XCTAssertEqual(capturedRequests[0].postID, "root-reaction-target")

    let didDeactivate = await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post)

    XCTAssertTrue(didDeactivate)
    await Task.yield()
    XCTAssertEqual(capturedRequests.count, 1)
  }

  func testRestoredArchiveReachesPushServiceBeforeSessionHistory() async throws {
    var updates: [PushArchiveState] = []
    let (session, container) = try makeSession(syncArchiveState: { updates.append($0) })
    try session.identityService.createNewIdentity()
    let keypair = try XCTUnwrap(session.identityService.keypair)
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: keypair.publicKey.hex) }
    session.receivePrivatePreference(
      try PrivatePreferenceCodec().event(
        for: .archive(sessionID: "not-restored-yet", archived: true), keypair: keypair,
        createdAt: 100))
    await session.pushStateSyncTask?.value
    XCTAssertEqual(updates, [
      PushArchiveState(archivedConversationIDs: ["not-restored-yet"], knownConversationIDs: ["not-restored-yet"])
    ])
    container.mainContext.insert(
      try SessionDeletionTombstoneEntity(
        ownerPubkey: keypair.publicKey.hex, sessionID: "not-restored-yet",
        deletedByPubkey: keypair.publicKey.hex))
    try container.mainContext.save()
    session.schedulePushStateSync()
    await session.pushStateSyncTask?.value
    XCTAssertEqual(updates.last,
      PushArchiveState(archivedConversationIDs: [], knownConversationIDs: ["not-restored-yet"]))
  }

  func testSessionRestoredBeforeItsPreferenceDoesNotSendAnAssumedUnarchive() async throws {
    var updates: [PushArchiveState] = []
    let (session, container) = try makeSession(syncArchiveState: { updates.append($0) })
    try session.identityService.createNewIdentity()
    let keypair = try XCTUnwrap(session.identityService.keypair)
    let owner = keypair.publicKey.hex
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    session.schedulePushStateSync()
    await session.pushStateSyncTask?.value
    let restored = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner,
      memberPubkeys: [owner], sessionID: "restored-session")
    session.preparePrivatePreferenceBackup()
    await session.pushStateSyncTask?.value
    XCTAssertTrue(updates.isEmpty, "restoring a session does not establish an archive choice")
    for (timestamp, archived) in [(100, true), (101, false)] {
      session.receivePrivatePreference(
        try PrivatePreferenceCodec().event(
          for: .archive(sessionID: restored.sessionID, archived: archived), keypair: keypair,
          createdAt: Int64(timestamp)))
      await session.pushStateSyncTask?.value
      XCTAssertEqual(restored.isArchived, archived)
    }
    XCTAssertEqual(updates, [
      PushArchiveState(archivedConversationIDs: ["restored-session"], knownConversationIDs: ["restored-session"]),
      PushArchiveState(archivedConversationIDs: [], knownConversationIDs: ["restored-session"])
    ])
  }

  func testPushSyncSerializesChangesDuringAnOutstandingRequest() async throws {
    let started = expectation(description: "first sync started")
    var finish: CheckedContinuation<Void, Never>?
    var updates: [PushArchiveState] = []
    let (session, container) = try makeSession(syncArchiveState: { state in
      updates.append(state)
      if updates.count == 1 {
        await withCheckedContinuation {
          finish = $0
          started.fulfill()
        }
      }
    })
    defer { withExtendedLifetime(container) {} }
    try session.identityService.createNewIdentity()
    session.setSessionArchived(sessionID: "session", archived: true)
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    session.setSessionArchived(sessionID: "session", archived: false)
    await Task.yield()
    XCTAssertEqual(updates.count, 1)
    finish?.resume()
    await session.pushStateSyncTask?.value
    XCTAssertEqual(updates, [
      PushArchiveState(archivedConversationIDs: ["session"], knownConversationIDs: ["session"]),
      PushArchiveState(archivedConversationIDs: [], knownConversationIDs: ["session"])
    ])
  }

  func testAccountChangeCancelsRemainingPushBatchesAndKeepsTheNewAccountsState() async throws {
    let started = expectation(description: "old account sync started")
    var finish: CheckedContinuation<Void, Never>?
    var updates: [PushArchiveState] = []
    let (session, container) = try makeSession(syncArchiveState: { state in
      updates.append(state)
      if updates.count == 1 {
        await withCheckedContinuation {
          finish = $0
          started.fulfill()
        }
      }
    })
    defer { withExtendedLifetime(container) {} }
    try session.identityService.createNewIdentity()
    let oldIDs = (0..<201).map { "old-session-\($0)" }.sorted()
    for id in oldIDs { session.setSessionArchived(sessionID: id, archived: true) }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    let oldTask = session.pushStateSyncTask
    session.resetPushSyncState()
    let newAccount = try TestKeyMaterialFactory.makeKeypair()
    try session.identityService.importNsec(newAccount.privateKey.nsec)
    session.setSessionArchived(sessionID: "new-session", archived: true)
    await session.pushStateSyncTask?.value
    finish?.resume()
    await oldTask?.value
    let newState = PushArchiveState(
      archivedConversationIDs: ["new-session"], knownConversationIDs: ["new-session"])
    XCTAssertEqual(updates, [
      PushArchiveState(
        archivedConversationIDs: Array(oldIDs.prefix(200)), knownConversationIDs: Array(oldIDs.prefix(200))),
      newState
    ])
    XCTAssertEqual(session.lastSyncedPushArchiveState?.ownerPubkey, newAccount.publicKey.hex)
    XCTAssertEqual(session.lastSyncedPushArchiveState?.state, newState)
  }

  func testMigratedArchiveChoicesRetryAfterPartialFailureWithoutLosingIDs() async throws {
    var updates: [PushArchiveState] = []
    let (session, container) = try makeSession(syncArchiveState: { state in
      updates.append(state)
      if updates.count == 2 { throw URLError(.notConnectedToInternet) }
    })
    try session.identityService.createNewIdentity()
    let keypair = try XCTUnwrap(session.identityService.keypair)
    let owner = keypair.publicKey.hex
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    let ids = (0..<450).map { _ in UUID().uuidString }.sorted()
    for id in ids {
      let entity = try SessionEntity(
        ownerPubkey: owner, sessionID: id, name: "Session", createdByPubkey: owner,
        createdAt: .now, updatedAt: .now)
      entity.isArchived = true
      container.mainContext.insert(entity)
    }
    try container.mainContext.save()
    for id in ids.suffix(50) {
      try session.privatePreferenceStore.save(.archive(sessionID: id, archived: false), keypair: keypair)
    }
    session.preparePrivatePreferenceBackup()
    await session.pushStateSyncTask?.value
    XCTAssertNil(session.lastSyncedPushArchiveState)
    session.schedulePushStateSync()
    await session.pushStateSyncTask?.value
    XCTAssertEqual(updates.map { $0.knownConversationIDs.count }, [200, 200, 200, 200, 50])
    let retried = updates.dropFirst(2)
    XCTAssertEqual(retried.flatMap(\.knownConversationIDs), ids)
    XCTAssertEqual(retried.flatMap(\.archivedConversationIDs), Array(ids.prefix(400)))
    XCTAssertEqual(session.lastSyncedPushArchiveState?.state,
      PushArchiveState(archivedConversationIDs: Array(ids.prefix(400)), knownConversationIDs: ids))
  }
}
