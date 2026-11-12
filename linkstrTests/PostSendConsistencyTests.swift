import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class PostSendConsistencyTests: AppSessionTestCase {
  func testPostCompletionPreservesAnExistingEchoOrItsDeletion() async throws {
    for deletePost in [false, true] {
      var release: CheckedContinuation<Void, Never>?
      var sent: LinkstrPayload?
      var pushCount = 0
      let started = expectation(description: "post awaiting acceptance")
      let acceptedTransportID = String(repeating: "b", count: 64)
      let (session, container) = try makeSession(
        disableNostrStartup: false, hasConnectedRelays: { true },
        sendPayload: { payload, _ in
          sent = payload
          await withCheckedContinuation { release = $0; started.fulfill() }
          return SentPayloadReceipt(rumorEventID: "sent-post", publishedEventIDs: [acceptedTransportID])
        }, enqueuePushNotification: { _ in pushCount += 1 }
      )
      try session.identityService.createNewIdentity()
      let owner = try XCTUnwrap(session.identityService.pubkeyHex)
      let target = try insertSessionFixture(
        in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
      )
      let publication = Task {
        await session.createSessionPostAwaitingRelay(url: "https://example.com", note: "original", session: target)
      }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      try persistEcho(session, owner: owner, payload: XCTUnwrap(sent), deletePost: deletePost)
      release?.resume()
      let didSend = await publication.value
      await Task.yield()

      XCTAssertEqual(didSend, !deletePost)
      let posts = try fetchMessages(in: container.mainContext)
      XCTAssertEqual(posts.count, deletePost ? 0 : 1)
      if deletePost {
        XCTAssertEqual(pushCount, 0)
      } else {
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.note, "edited on another device")
        XCTAssertEqual(post.noteEditEventID, "note-edit")
        XCTAssertEqual(post.metadataTitle, "loaded preview")
        XCTAssertTrue(post.isArchived)
        XCTAssertEqual(Set(post.publishedTransportEventIDs), [String(repeating: "a", count: 64), acceptedTransportID])
      }
    }
  }

  private func persistEcho(
    _ session: AppSession, owner: String, payload: LinkstrPayload, deletePost: Bool
  ) throws {
    let timestamp = Date(timeIntervalSince1970: TimeInterval(payload.timestamp))
    let post = try SessionMessageEntity(
      eventID: "sent-post", ownerPubkey: owner, conversationID: payload.conversationID,
      rootID: "sent-post", kind: .root, senderPubkey: owner, url: payload.url, note: payload.note,
      timestamp: timestamp, isArchived: true, readAt: timestamp, linkType: .generic,
      metadataTitle: "loaded preview", publishedTransportEventIDs: [String(repeating: "a", count: 64)]
    )
    post.applyNoteRevision(
      ciphertext: try LocalDataCrypto.shared.encryptString("edited on another device", ownerPubkey: owner),
      editedAt: timestamp.addingTimeInterval(1), eventID: "note-edit"
    )
    try session.messageStore.insert(post)
    if deletePost {
      try session.messageStore.applyRootDeletion(ApplyRootDeletionParams(
        ownerPubkey: owner, sessionID: payload.conversationID, rootID: "sent-post", deletedByPubkey: owner,
        updatedAt: timestamp.addingTimeInterval(2), eventID: String(repeating: "c", count: 64)
      ))
    }
  }

  func testPostRechecksMembersWithoutChangingDestinationAfterWaitingForARelay() async throws {
    for senderRemoved in [false, true] {
      var connected = false
      var checkedConnection = false
      var recipients: [String] = []
      var sentSessionID: String?
      let started = expectation(description: "waiting for connection")
      let (session, container) = try makeSession(
        disableNostrStartup: false,
        hasConnectedRelays: {
          if !checkedConnection {
            checkedConnection = true
            started.fulfill()
          }
          return connected
        },
        sendPayload: { payload, targets in
          sentSessionID = payload.conversationID
          recipients = targets
          return SentPayloadReceipt(rumorEventID: "sent-post", publishedEventIDs: [])
        }
      )
      try session.identityService.createNewIdentity()
      let owner = try XCTUnwrap(session.identityService.pubkeyHex)
      let formerMember = try TestKeyMaterialFactory.makePubkeyHex()
      let newMember = try TestKeyMaterialFactory.makePubkeyHex()
      let target = try insertSessionFixture(
        in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner, formerMember]
      )
      container.mainContext.insert(RelayEntity(url: "wss://relay.example.com"))
      try container.mainContext.save()
      let publication = Task {
        await session.createSessionPostAwaitingRelay(url: "https://example.com", note: nil, session: target)
      }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      _ = try insertSessionFixture(
        in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner,
        memberPubkeys: [owner], sessionID: "newer-destination"
      )
      try session.messageStore.applyMemberSnapshot(
        ownerPubkey: owner, sessionID: target.sessionID,
        memberPubkeys: senderRemoved ? [newMember] : [owner, newMember], updatedAt: .now, eventID: "members-update"
      )
      connected = true
      let didSend = await publication.value

      XCTAssertEqual(didSend, !senderRemoved)
      XCTAssertEqual(sentSessionID, senderRemoved ? nil : target.sessionID)
      XCTAssertEqual(Set(recipients), senderRemoved ? [] : [owner, newMember])
      XCTAssertEqual(try fetchMessages(in: container.mainContext).count, senderRemoved ? 0 : 1)
    }
  }

  func testPostCompletionPreservesItsTimestampAndDoesNotRecreateADeletedSession() async throws {
    for deleteSession in [false, true] {
      var release: CheckedContinuation<Void, Never>?
      var sent: LinkstrPayload?
      var pushCount = 0
      let started = expectation(description: "post publication started")
      let (session, container) = try makeSession(
        disableNostrStartup: false, hasConnectedRelays: { true },
        sendPayload: { payload, _ in
          sent = payload
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
          return SentPayloadReceipt(rumorEventID: "sent-post", publishedEventIDs: [])
        }, enqueuePushNotification: { _ in pushCount += 1 }
      )
      try session.identityService.createNewIdentity()
      let owner = try XCTUnwrap(session.identityService.pubkeyHex)
      let target = try insertSessionFixture(
        in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
      )
      let publication = Task {
        await session.createSessionPostAwaitingRelay(url: "https://example.com", note: nil, session: target)
      }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      if deleteSession {
        try session.messageStore.applySessionDeletion(
          ownerPubkey: owner, sessionID: target.sessionID, deletedByPubkey: owner,
          updatedAt: .now, eventID: "delete-session"
        )
      }
      release?.resume()
      let didSend = await publication.value
      await Task.yield()

      XCTAssertEqual(didSend, !deleteSession)
      let posts = try fetchMessages(in: container.mainContext)
      XCTAssertEqual(posts.count, deleteSession ? 0 : 1)
      XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<SessionEntity>()), deleteSession ? 0 : 1)
      if deleteSession {
        XCTAssertEqual(pushCount, 0)
      } else {
        XCTAssertEqual(posts.first?.timestamp, Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(sent).timestamp)))
      }
    }
  }
}
