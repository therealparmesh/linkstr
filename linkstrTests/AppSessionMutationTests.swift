import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class AppSessionMutationTests: AppSessionTestCase {
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
  }

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
    XCTAssertEqual(session.composeError, "couldn't reconnect to relays in time. try again.")
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

    let didCreate = await session.createSessionPostAwaitingRelay(
      url: "https://example.com/path",
      note: nil,
      session: sessionEntity,
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
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
      "connected relays are read-only. add a writable relay to send."
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
      "connected relays are read-only. add a writable relay to send."
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
      session.composeError, "no relays are enabled. enable at least one relay in settings.")
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
    let message = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertEqual(message.eventID, "root-rumor-id")
    XCTAssertEqual(message.rootID, "root-rumor-id")
    XCTAssertEqual(message.publishedTransportEventIDs, ["giftwrap-root-a", "giftwrap-root-b"])
  }
}
