import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class SessionMutationLifetimeTests: AppSessionTestCase {
  private enum Operation: CaseIterable {
    case create, members, deleteSession, deletePost
  }

  func testRelayWaitStopsWithoutOverwritingErrorsAfterItsContextChanges() async throws {
    for replaceAccount in [false, true] {
      var didCheck = false
      let started = expectation(description: "relay wait checked the connection")
      let (session, container) = try makeSession(
        disableNostrStartup: false,
        hasConnectedRelays: {
          if !didCheck {
            didCheck = true
            started.fulfill()
          }
          return false
        }
      )
      try session.identityService.createNewIdentity()
      container.mainContext.insert(RelayEntity(url: "wss://relay.example.com"))
      try container.mainContext.save()
      let waiting = Task {
        await session.awaitRelayReadyForSend(timeoutSeconds: 0.15, pollIntervalSeconds: 0.05)
      }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      if replaceAccount {
        session.importNsec(try TestKeyMaterialFactory.makeKeypair().privateKey.nsec)
      } else {
        session.replaceNostrService()
      }
      session.composeError = "current message"
      let isReady = await waiting.value

      XCTAssertFalse(isReady)
      XCTAssertEqual(session.composeError, "current message")
    }
  }

  func testSessionAndDeletionCompletionsStayWithinTheirOriginalContext() async throws {
    for operation in Operation.allCases {
      for transition in ["account", "relay", "cancel"] {
        for rejects in [false, true] {
          try await assertLateCompletionIgnored(operation, transition: transition, rejects: rejects)
        }
      }
    }
  }

  func testRelayDeletionCleanupCannotContinueOrReportErrorsInAnotherAccount() async throws {
    for operation in [Operation.deletePost, .deleteSession] {
      for rejects in [false, true] {
        var release: CheckedContinuation<Void, Never>?
        var sentPayloads = 0
        let started = expectation(description: "relay deletion started")
        let (session, container) = try makeSession(
          disableNostrStartup: false, hasConnectedRelays: { true },
          publishRelayEvent: { _ in
            await withCheckedContinuation {
              release = $0
              started.fulfill()
            }
            if rejects { throw URLError(.cannotConnectToHost) }
            return "relay-deletion"
          },
          sendPayload: { _, _ in
            sentPayloads += 1
            return SentPayloadReceipt(rumorEventID: "deletion-notice", publishedEventIDs: [])
          }
        )
        try session.identityService.createNewIdentity()
        let owner = try XCTUnwrap(session.identityService.pubkeyHex)
        let (target, post) = try insertTargets(in: container, owner: owner, transportIDs: ["original-wrapper"])
        let publication = Task { await perform(operation, session: session, target: target, post: post) }
        await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
        session.importNsec(try TestKeyMaterialFactory.makeKeypair().privateKey.nsec)
        session.composeError = "current message"
        release?.resume()
        let didSucceed = await publication.value

        XCTAssertFalse(didSucceed)
        XCTAssertEqual(session.composeError, "current message")
        XCTAssertEqual(sentPayloads, operation == .deleteSession ? 1 : 0)
        XCTAssertEqual(try fetchMessages(in: container.mainContext).count, operation == .deleteSession ? 0 : 1)
      }
    }
  }

  func testMemberUpdateCannotRecreateASessionDeletedWhilePublishing() async throws {
    var release: CheckedContinuation<Void, Never>?
    let started = expectation(description: "membership publication started")
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { _, _ in
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        return SentPayloadReceipt(rumorEventID: "late-members", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let (target, post) = try insertTargets(in: container, owner: owner)
    let publication = Task { await perform(.members, session: session, target: target, post: post) }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    container.mainContext.delete(target)
    try container.mainContext.save()
    release?.resume()
    let didSucceed = await publication.value

    XCTAssertFalse(didSucceed)
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SessionEntity>()).isEmpty)
    XCTAssertEqual(session.composeError, "this session is no longer available.")
  }

  private func assertLateCompletionIgnored(_ operation: Operation, transition: String, rejects: Bool) async throws {
    var release: CheckedContinuation<Void, Never>?
    let started = expectation(description: "publication started")
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { _, _ in
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        if rejects { throw URLError(.cannotConnectToHost) }
        return SentPayloadReceipt(rumorEventID: "late-mutation", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let (target, post) = try insertTargets(in: container, owner: owner)
    let publication = Task { await perform(operation, session: session, target: target, post: post) }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    switch transition {
    case "account": session.importNsec(try TestKeyMaterialFactory.makeKeypair().privateKey.nsec)
    case "relay": session.replaceNostrService()
    default: publication.cancel()
    }
    session.composeError = "current message"
    release?.resume()
    let didSucceed = await publication.value

    XCTAssertFalse(didSucceed, "\(operation), \(transition), rejects: \(rejects)")
    let sessions = try container.mainContext.fetch(FetchDescriptor<SessionEntity>())
    XCTAssertEqual(sessions.map(\.name), ["Test Session"])
    XCTAssertEqual(try fetchMessages(in: container.mainContext).map(\.rootID), ["existing-post"])
    XCTAssertNil(session.pendingSessionNavigationRequest)
    XCTAssertEqual(session.composeError, "current message")
  }

  private func insertTargets(in container: ModelContainer, owner: String, transportIDs: [String] = []) throws
    -> (SessionEntity, SessionMessageEntity) {
    let target = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
    )
    let post = try makeMessage(
      eventID: "existing-post", conversationID: target.sessionID, rootID: "existing-post",
      senderPubkey: owner, ownerPubkey: owner, publishedTransportEventIDs: transportIDs
    )
    container.mainContext.insert(post)
    try container.mainContext.save()
    return (target, post)
  }

  private func perform(
    _ operation: Operation, session: AppSession, target: SessionEntity, post: SessionMessageEntity
  ) async -> Bool {
    switch operation {
    case .create: await session.createSessionAwaitingRelay(name: "Late Session", memberNPubs: [])
    case .members:
      await session.updateSessionMembersAwaitingRelay(session: target, memberNPubs: [], sessionName: "Late Name")
    case .deleteSession: await session.deleteSessionAwaitingRelay(target)
    case .deletePost: await session.deletePostAwaitingRelay(post)
    }
  }
}
