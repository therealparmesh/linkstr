import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

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

    let post = makeMessage(
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

    let didDeactivate = await session.toggleReactionAwaitingRelay(emoji: "🔥", post: post)

    XCTAssertTrue(didDeactivate)
    await Task.yield()
    XCTAssertEqual(capturedRequests.count, 1)
  }

  func testSetSessionArchivedSyncsArchivedConversationIDsToPushService() async throws {
    var syncedConversationIDs: [[String]] = []
    let archiveExpectation = expectation(description: "archive sync")
    let unarchiveExpectation = expectation(description: "unarchive sync")

    let (session, container) = try makeSession(
      syncArchivedConversationIDs: { conversationIDs in
        syncedConversationIDs.append(conversationIDs.sorted())
        if syncedConversationIDs.count == 1 {
          archiveExpectation.fulfill()
        } else if syncedConversationIDs.count == 2 {
          unarchiveExpectation.fulfill()
        }
      }
    )

    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    _ = try insertSessionFixture(
      in: container.mainContext,
      ownerPubkey: myPubkey,
      createdByPubkey: myPubkey,
      memberPubkeys: [myPubkey],
      sessionID: "session-archive-target"
    )

    session.setSessionArchived(sessionID: "session-archive-target", archived: true)
    await fulfillment(of: [archiveExpectation], timeout: asyncExpectationTimeoutSeconds)
    XCTAssertEqual(syncedConversationIDs, [["session-archive-target"]])

    session.setSessionArchived(sessionID: "session-archive-target", archived: false)
    await fulfillment(of: [unarchiveExpectation], timeout: asyncExpectationTimeoutSeconds)
    XCTAssertEqual(syncedConversationIDs, [["session-archive-target"], []])
  }
}
