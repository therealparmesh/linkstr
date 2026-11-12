import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class ProfileMutationLifetimeTests: AppSessionTestCase {
  func testReplacedRelayCannotReportLateProfilePublicationFailure() async throws {
    for rejects in [false, true] {
      let started = expectation(description: "profile publication started")
      var release: CheckedContinuation<Void, Never>?
      let (session, container) = try makeSession(
        disableNostrStartup: false, hasConnectedRelays: { true },
        publishRelayEvent: { event in
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
          if rejects { throw URLError(.cannotConnectToHost) }
          return event.id
        }
      )
      try session.identityService.createNewIdentity()
      let publication = Task { await session.updateOwnProfileName("obsolete name") }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      session.replaceNostrService()
      session.profileNameErrorMessage = "current profile problem"
      session.composeError = "current message"
      release?.resume()
      let result = await publication.value

      XCTAssertFalse(result)
      XCTAssertNil(session.currentProfileName)
      XCTAssertEqual(session.profileNameErrorMessage, "current profile problem")
      XCTAssertEqual(session.composeError, "current message")
      XCTAssertNil(try fetchAccountStates(in: container.mainContext).first?.nostrProfileName)
    }
  }

  func testReplacedRelayWaitCannotOverwriteCurrentProfileError() async throws {
    let started = expectation(description: "profile checked relay connection")
    var checked = false
    var published = false
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: {
        if !checked {
          checked = true
          started.fulfill()
        }
        return false
      },
      publishRelayEvent: { event in
        published = true
        return event.id
      }
    )
    try session.identityService.createNewIdentity()
    container.mainContext.insert(RelayEntity(url: "wss://relay.example.com"))
    try container.mainContext.save()
    let publication = Task {
      await session.updateOwnProfileName("obsolete name", timeoutSeconds: 0.2, pollIntervalSeconds: 0.05)
    }
    await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
    session.replaceNostrService()
    session.profileNameErrorMessage = "current profile problem"
    session.composeError = "current message"
    let result = await publication.value

    XCTAssertFalse(result)
    XCTAssertFalse(published)
    XCTAssertEqual(session.profileNameErrorMessage, "current profile problem")
    XCTAssertEqual(session.composeError, "current message")
  }
}
