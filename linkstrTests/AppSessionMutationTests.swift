import SwiftData
import XCTest

@testable import linkstr

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

    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com"))
    try container.mainContext.save()

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(session.composeError, "couldn’t reconnect to relays in time. try again.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionSetsPendingNavigationRequest() async throws {
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
    XCTAssertEqual(session.pendingSessionNavigationRequest?.sessionID, sessions.first?.sessionID)

    session.clearPendingSessionNavigationRequest()
    XCTAssertNil(session.pendingSessionNavigationRequest)
  }

  func testRequestSessionNavigationReplacesRequestForRepeatedSessionID() throws {
    let (session, _) = try makeSession()

    session.requestSessionNavigation(to: "session-repeat")
    let firstRequestID = session.pendingSessionNavigationRequest?.id

    session.requestSessionNavigation(to: "session-repeat")

    XCTAssertEqual(session.pendingSessionNavigationRequest?.sessionID, "session-repeat")
    XCTAssertNotEqual(session.pendingSessionNavigationRequest?.id, firstRequestID)
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

    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .readOnly)

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError,
      "your connected relays are read-only. enable a writable relay to send."
    )
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostAwaitingRelayWithLiveReadOnlyRelaysStillBlocksSend() async throws {
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true }
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

    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .readOnly)

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertFalse(didCreate)
    XCTAssertEqual(
      session.composeError,
      "your connected relays are read-only. enable a writable relay to send."
    )
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostAwaitingRelayWithNoEnabledRelaysShowsNoEnabledRelaysMessage()
    async throws {
    let (session, container) = try makeSession(disableNostrStartup: false)
    try session.identityService.createNewIdentity()
    await session.boot()
    for relay in session.configuredRelays {
      session.removeRelay(relay)
    }
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
    XCTAssertEqual(
      session.composeError, "enable a relay in settings to continue.")
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testCreateSessionPostPersistsLocalRootMessageWithoutRelayTransportMetadata() async throws {
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
    XCTAssertEqual(message.rootID, message.eventID)
    XCTAssertTrue(message.publishedTransportEventIDs.isEmpty)
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
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didCreate)
    XCTAssertNil(session.composeError)
    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 1)
    let message = try XCTUnwrap(messages.first)
    XCTAssertEqual(message.eventID, "root-rumor-id")
    XCTAssertEqual(message.rootID, "root-rumor-id")
    XCTAssertEqual(message.publishedTransportEventIDs, ["giftwrap-root-a", "giftwrap-root-b"])
  }
}

extension AppSessionMutationTests {
  func testLatePostCreationCannotWriteOrNotifyAfterAccountChangesOrCancellation() async throws {
    for transition in ["account", "relay", "cancel"] {
      for relayRejects in [false, true] {
        var release: CheckedContinuation<Void, Never>?
        var pushes = 0
        let started = expectation(description: "post publication started")
        let (session, container) = try makeSession(
          disableNostrStartup: false, hasConnectedRelays: { true },
          sendPayload: { _, _ in
            await withCheckedContinuation {
              release = $0
              started.fulfill()
            }
            if relayRejects { throw URLError(.cannotConnectToHost) }
            return SentPayloadReceipt(rumorEventID: "late-post", publishedEventIDs: [])
          },
          enqueuePushNotification: { _ in pushes += 1 }
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
        switch transition {
        case "account": session.importNsec(try TestKeyMaterialFactory.makeKeypair().privateKey.nsec)
        case "relay": session.replaceNostrService()
        default: publication.cancel()
        }
        session.composeError = "current message"
        release?.resume()
        let didCreate = await publication.value
        await Task.yield()

        XCTAssertFalse(didCreate, transition)
        XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty, transition)
        XCTAssertEqual(session.composeError, "current message", transition)
        XCTAssertEqual(pushes, 0, transition)
      }
    }
  }
}

extension AppSessionMutationTests {
  func testPerformFormMutationCapturesErrorAndRestoresGlobalToastPresentation() async throws {
    let (session, _) = try makeSession()

    let result = await session.performFormMutation {
      XCTAssertFalse(session.shouldPresentComposeErrorToast)
      session.composeError = "blocked: policy"
      return false
    }

    XCTAssertFalse(result.didSucceed)
    XCTAssertEqual(result.errorMessage, "blocked: policy")
    XCTAssertNil(session.composeError)
    XCTAssertTrue(session.shouldPresentComposeErrorToast)

    let unexplainedFailure = await session.performFormMutation { false }
    XCTAssertFalse(unexplainedFailure.didSucceed)
    XCTAssertEqual(unexplainedFailure.errorMessage, "couldn’t complete this action. try again.")

    let success = await session.performFormMutation { true }
    XCTAssertTrue(success.didSucceed)
    XCTAssertNil(success.errorMessage)
  }

  func testObsoleteFormDoesNotCaptureCurrentErrorsOrSuppressAnotherContext() async throws {
    for transition in ["account", "relay", "cancel"] {
      let (session, _) = try makeSession()
      try session.identityService.createNewIdentity()
      let started = expectation(description: "form mutation started")
      var release: CheckedContinuation<Bool, Never>?
      let mutation = Task {
        await session.performFormMutation {
          await withCheckedContinuation { release = $0; started.fulfill() }
        }
      }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      XCTAssertFalse(session.shouldPresentComposeErrorToast)
      switch transition {
      case "account": session.importNsec(try TestKeyMaterialFactory.makeKeypair().privateKey.nsec)
      case "relay": session.replaceNostrService()
      default: mutation.cancel()
      }
      if transition != "cancel" { XCTAssertTrue(session.shouldPresentComposeErrorToast) }
      session.composeError = "current account error"
      let currentResult = await session.performFormMutation {
        release?.resume(returning: false)
        let result = await mutation.value
        XCTAssertFalse(result.didSucceed)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(session.composeError, "current account error")
        XCTAssertFalse(session.shouldPresentComposeErrorToast)
        return false
      }
      XCTAssertEqual(currentResult.errorMessage, "current account error")
      XCTAssertNil(session.composeError)
      XCTAssertTrue(session.shouldPresentComposeErrorToast)
    }
  }
}
