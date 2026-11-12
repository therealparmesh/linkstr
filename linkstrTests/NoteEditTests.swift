import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class NoteEditTests: AppSessionTestCase {
  func testDelayedAcceptanceDoesNotOverwriteANewerNoteRevision() async throws {
    var release: CheckedContinuation<Void, Never>?
    var sentTimestamp: Int64?
    let started = expectation(description: "note publication started")
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { payload, _ in
        sentTimestamp = payload.timestamp
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        return SentPayloadReceipt(rumorEventID: "delayed-edit", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
    )
    let post = try makePost(owner: owner, author: owner, timestamp: .now.addingTimeInterval(-10))
    container.mainContext.insert(post)
    try container.mainContext.save()

    let publication = Task { await session.editPostNoteAwaitingRelay("delayed draft", on: post) }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    let newerTimestamp = try XCTUnwrap(sentTimestamp) + 1
    session.persistIncoming(message(
      id: "newer-edit", author: owner, kind: .noteEdit, note: "newer revision", at: newerTimestamp
    ))
    XCTAssertEqual(post.note, "newer revision")
    release?.resume()
    let didEdit = await publication.value

    XCTAssertFalse(didEdit)
    XCTAssertEqual(post.note, "newer revision")
    XCTAssertEqual(post.noteEditEventID, "newer-edit")
    XCTAssertEqual(session.composeError, "a newer edit is already saved. review the note and try again.")
    XCTAssertTrue(session.pendingNoteEdits.isEmpty)
  }

  func testLateNoteEditRespectsAccountChangesCancellationAndPostDeletion() async throws {
    for transition in ["account", "relay", "cancel", "delete"] {
      for relayRejects in [false, true] {
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "note publication started")
        let (session, container) = try makeSession(
          disableNostrStartup: false, hasConnectedRelays: { true },
          sendPayload: { _, _ in
            await withCheckedContinuation {
              release = $0
              started.fulfill()
            }
            if relayRejects { throw URLError(.cannotConnectToHost) }
            return SentPayloadReceipt(rumorEventID: "late-edit", publishedEventIDs: [])
          }
        )
        try session.identityService.createNewIdentity()
        let owner = try XCTUnwrap(session.identityService.pubkeyHex)
        _ = try insertSessionFixture(
          in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
        )
        let post = try makePost(owner: owner, author: owner, timestamp: .now.addingTimeInterval(-10))
        container.mainContext.insert(post)
        try container.mainContext.save()
        let publication = Task { await session.editPostNoteAwaitingRelay("late edit", on: post) }
        await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
        switch transition {
        case "account": session.importNsec(try TestKeyMaterialFactory.makeKeypair().privateKey.nsec)
        case "relay": session.replaceNostrService()
        case "delete":
          container.mainContext.delete(post)
          try container.mainContext.save()
        default: publication.cancel()
        }
        session.composeError = "current message"
        release?.resume()
        let didEdit = await publication.value

        XCTAssertFalse(didEdit, transition)
        if transition == "delete" {
          XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
          XCTAssertNotNil(session.composeError)
          if !relayRejects { XCTAssertEqual(session.composeError, "this post is no longer available.") }
        } else {
          XCTAssertEqual(post.note, "original", transition)
          XCTAssertNil(post.noteEditedAt, transition)
          XCTAssertEqual(session.composeError, "current message", transition)
        }
        XCTAssertTrue(session.pendingNoteEdits.isEmpty)
      }
    }
  }

  func testEditWaitsForAcceptanceAndOnlySendsToEligibleMembers() async throws {
    var deliveries: [(LinkstrPayload, [String])] = []
    var reject = true
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      sendPayload: { payload, recipients in
        deliveries.append((payload, recipients))
        if reject { throw NostrServiceError.publishTimedOut }
        return SentPayloadReceipt(rumorEventID: "note-edit-\(deliveries.count)", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let originalMember = try TestKeyMaterialFactory.makePubkeyHex()
    let newMember = try TestKeyMaterialFactory.makePubkeyHex()
    let originalTime = Date.now.addingTimeInterval(-120)
    let context = container.mainContext
    _ = try insertSessionFixture(
      in: context, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner, originalMember, newMember]
    )
    context.insert(try SessionMemberIntervalEntity(
      ownerPubkey: owner, sessionID: "session-fixture", memberPubkey: originalMember, startAt: originalTime
    ))
    let post = try makePost(owner: owner, author: owner, timestamp: originalTime)
    context.insert(post)
    try context.save()

    let didReject = await session.editPostNoteAwaitingRelay("edited", on: post)
    XCTAssertFalse(didReject)
    XCTAssertEqual(post.note, "original")
    XCTAssertNil(post.noteEditedAt)

    reject = false
    let didEdit = await session.editPostNoteAwaitingRelay("  edited  ", on: post)
    XCTAssertTrue(didEdit)
    let delivery = try XCTUnwrap(deliveries.last)
    XCTAssertEqual(delivery.0.kind, .noteEdit)
    XCTAssertEqual(delivery.0.rootID, post.rootID)
    XCTAssertEqual(delivery.0.note, "edited")
    XCTAssertNil(delivery.0.url)
    XCTAssertEqual(Set(delivery.1), [owner, originalMember])
    XCTAssertEqual(post.note, "edited")
    XCTAssertEqual(post.url, "https://example.com/link")
    XCTAssertEqual(post.timestamp, originalTime)
    XCTAssertEqual(post.readAt, originalTime)
    XCTAssertEqual(post.publishedTransportEventIDs, ["original-wrapper"])
    XCTAssertEqual(try fetchMessages(in: context).count, 1)
  }

  func testInboundEditWaitsForRootAndOnlyAppliesNewerAuthorRevisions() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let author = try TestKeyMaterialFactory.makePubkeyHex()
    let otherMember = try TestKeyMaterialFactory.makePubkeyHex()
    _ = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner,
      memberPubkeys: [owner, author, otherMember]
    )
    let start = Int64(Date.now.timeIntervalSince1970) + 2
    session.persistIncoming(message(id: "edit-b", author: author, kind: .noteEdit, note: "new note", at: start + 2))
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)

    session.persistIncoming(message(id: "post", author: author, kind: .root, note: "original", at: start))
    let post = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(post.note, "new note")
    session.persistIncoming(message(id: "edit-old", author: author, kind: .noteEdit, note: "old", at: start + 1))
    session.persistIncoming(message(id: "edit-a", author: author, kind: .noteEdit, note: "loser", at: start + 2))
    session.persistIncoming(
      message(id: "edit-other", author: otherMember, kind: .noteEdit, note: "spoof", at: start + 3)
    )
    XCTAssertEqual(post.note, "new note")
    session.persistIncoming(message(id: "edit-c", author: author, kind: .noteEdit, note: nil, at: start + 4))
    XCTAssertNil(post.note)
    XCTAssertEqual(post.noteEditEventID, "edit-c")
    XCTAssertEqual(post.rootID, "post")
  }

  private func makePost(owner: String, author: String, timestamp: Date) throws -> SessionMessageEntity {
    try SessionMessageEntity(
      eventID: "post", ownerPubkey: owner, conversationID: "session-fixture", rootID: "post",
      kind: .root, senderPubkey: author, url: "https://example.com/link", note: "original",
      timestamp: timestamp, readAt: timestamp, linkType: .generic, publishedTransportEventIDs: ["original-wrapper"]
    )
  }

  private func message(
    id: String, author: String, kind: LinkstrPayloadKind, note: String?, at timestamp: Int64
  ) -> ReceivedDirectMessage {
    ReceivedDirectMessage(
      eventID: id, transportEventID: nil, senderPubkey: author,
      payload: LinkstrPayload(
        conversationID: "session-fixture", rootID: kind == .root ? "" : "post", kind: kind,
        url: kind == .root ? "https://example.com/link" : nil, note: note, timestamp: timestamp
      ),
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)), source: .historical
    )
  }
}
