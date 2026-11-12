import SwiftData
import XCTest

@testable import linkstr

@MainActor
extension AppSessionMutationTests {
  func testFailedReactionDoesNotBlockAnotherEmojiOrInvertTheNextTap() async throws {
    var release: CheckedContinuation<Void, Never>?
    var firePayloads: [LinkstrPayload] = []
    let started = expectation(description: "first reaction started")
    let independentFinished = expectation(description: "another emoji does not wait")
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { payload, _ in
        if payload.emoji == "🔥" {
          firePayloads.append(payload)
          if firePayloads.count == 1 {
            await withCheckedContinuation {
              release = $0
              started.fulfill()
            }
            throw URLError(.cannotConnectToHost)
          }
        }
        return SentPayloadReceipt(rumorEventID: "accepted-reaction", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let post = try insertReactionTarget(container: container, owner: owner)
    let first = Task { await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post) }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    let second = Task { await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post) }
    let independent = Task {
      let result = await session.toggleReactionAwaitingRelay(emoji: "👍", post: post)
      independentFinished.fulfill()
      return result
    }
    await fulfillment(of: [independentFinished], timeout: asyncExpectationTimeoutSeconds)
    release?.resume()
    let results = await [first.value, second.value, independent.value]

    XCTAssertEqual(results, [false, true, true])
    XCTAssertEqual(firePayloads.map(\.reactionActive), [true, true])
    let reactions = try fetchReactions(in: container.mainContext)
    XCTAssertEqual(Set(reactions.filter(\.isActive).map(\.emoji)), ["🔥", "👍"])
  }

  func testRapidReactionTapsUseTheLastAcceptedStateAndKeepRemoteOrdering() async throws {
    var release: CheckedContinuation<Void, Never>?
    var firstIsPending = true
    var payloads: [LinkstrPayload] = []
    let started = expectation(description: "first reaction publication started")
    let overlappingSend = expectation(description: "second reaction must wait for the first")
    overlappingSend.isInverted = true
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { payload, _ in
        payloads.append(payload)
        if payloads.count == 1 {
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
          return SentPayloadReceipt(rumorEventID: "z-first", publishedEventIDs: [])
        }
        if firstIsPending { overlappingSend.fulfill() }
        return SentPayloadReceipt(rumorEventID: "a-second", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let post = try insertReactionTarget(container: container, owner: owner)
    let first = Task { await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post) }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    let second = Task { await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post) }
    await fulfillment(of: [overlappingSend], timeout: 0.05)
    firstIsPending = false
    release?.resume()
    let results = await [first.value, second.value]

    XCTAssertEqual(results, [true, true])
    XCTAssertEqual(payloads.map(\.reactionActive), [true, false])
    XCTAssertEqual(payloads.count, 2)
    let firstPayload = try XCTUnwrap(payloads.first)
    let lastPayload = try XCTUnwrap(payloads.last)
    XCTAssertGreaterThan(lastPayload.timestamp, firstPayload.timestamp)
    let reaction = try XCTUnwrap(fetchReactions(in: container.mainContext).first)
    XCTAssertFalse(reaction.isActive)
    XCTAssertEqual(reaction.updatedAt, Date(timeIntervalSince1970: TimeInterval(lastPayload.timestamp)))
  }

  func testReactionCompletionCannotModifyAnotherAccountOrReportStaleErrors() async throws {
    for relayRejects in [false, true] {
      var release: CheckedContinuation<Void, Never>?
      let started = expectation(description: "reaction publication started")
      var pushCount = 0
      var sendCount = 0
      let (session, container) = try makeSession(
        disableNostrStartup: false, hasConnectedRelays: { true },
        sendPayload: { _, _ in
          sendCount += 1
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
          if relayRejects { throw URLError(.cannotConnectToHost) }
          return SentPayloadReceipt(rumorEventID: "stale-reaction", publishedEventIDs: [])
        },
        enqueuePushNotification: { _ in pushCount += 1 }
      )
      try session.identityService.createNewIdentity()
      let owner = try XCTUnwrap(session.identityService.pubkeyHex)
      let post = try insertReactionTarget(container: container, owner: owner)
      let publication = Task { await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post) }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      let queued = Task { await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post) }
      let replacement = try TestKeyMaterialFactory.makeKeypair()
      session.importNsec(replacement.privateKey.nsec)
      session.composeError = "new account message"
      release?.resume()
      let didPublish = await publication.value
      let queuedDidPublish = await queued.value
      await Task.yield()

      XCTAssertFalse(didPublish)
      XCTAssertFalse(queuedDidPublish)
      XCTAssertEqual(sendCount, 1)
      XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
      XCTAssertEqual(session.composeError, "new account message")
      XCTAssertEqual(pushCount, 0)
    }
  }

  func testCancelledReactionDoesNotPersistOrShowAnErrorAfterRelayCompletion() async throws {
    var release: CheckedContinuation<Void, Never>?
    let started = expectation(description: "reaction publication started")
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { _, _ in
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        return SentPayloadReceipt(rumorEventID: "cancelled-reaction", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let post = try insertReactionTarget(container: container, owner: owner)
    let publication = Task { await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post) }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    publication.cancel()
    release?.resume()
    let didPublish = await publication.value

    XCTAssertFalse(didPublish)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    XCTAssertNil(session.composeError)
  }

  func testReactionRejectsPostFromAnotherAccountEvenWhenSessionIDsMatch() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let otherOwner = try TestKeyMaterialFactory.makePubkeyHex()
    let post = try insertReactionTarget(container: container, owner: otherOwner)
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner,
      memberPubkeys: [owner], sessionID: post.conversationID
    )

    let didPublish = await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post)

    XCTAssertFalse(didPublish)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
  }

  private func insertReactionTarget(container: ModelContainer, owner: String) throws
    -> SessionMessageEntity {
    let sessionEntity = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
    )
    let post = try makeMessage(
      eventID: "reaction-target", conversationID: sessionEntity.sessionID, rootID: "reaction-target",
      senderPubkey: owner, ownerPubkey: owner
    )
    container.mainContext.insert(post)
    try container.mainContext.save()
    return post
  }

}
