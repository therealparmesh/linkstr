import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionContactAndRelayTests {
  func testBootUsesVirtualDefaultRelaysWhenStoreIsEmpty() async throws {
    let (session, container) = try makeSession()

    await session.boot()

    XCTAssertEqual(session.configuredRelays.map(\.url), RelayDefaults.urls)
    XCTAssertTrue(try fetchPersistedRelays(in: container.mainContext).isEmpty)
  }

  func testBootLeavesPersistedRelayRowsInPlaceUntilResetDefaults() async throws {
    let relaySettingsUserDefaults = makeRelaySettingsUserDefaults()
    let (session, container) = try makeSession(
      relaySettingsUserDefaults: relaySettingsUserDefaults
    )
    let persistedRelayURLs = [
      "wss://relay.damus.io",
      "wss://relay.primal.net",
      "wss://nos.lol",
      "wss://relay.snort.social",
      "wss://nostr.satoshisfrens.win"
    ]

    persistedRelayURLs.forEach { container.mainContext.insert(RelayEntity(url: $0)) }
    try container.mainContext.save()

    await session.boot()

    XCTAssertEqual(session.configuredRelays.map(\.url), persistedRelayURLs)
    XCTAssertEqual(
      try fetchPersistedRelays(in: container.mainContext).map(\.url), persistedRelayURLs)
  }

  func testAddingCustomRelayMaterializesDefaultsAndRejectsDuplicates() throws {
    let (session, container) = try makeSession()

    session.addRelay(url: "https://invalid-relay.example.com")
    XCTAssertEqual(session.composeError, "enter a valid relay url (ws:// or wss://).")

    session.addRelay(url: "wss://")
    XCTAssertEqual(session.composeError, "enter a valid relay url (ws:// or wss://).")
    XCTAssertTrue(try fetchPersistedRelays(in: container.mainContext).isEmpty)

    session.addRelay(url: "wss://relay.example.com")
    var relays = try fetchPersistedRelays(in: container.mainContext)
    XCTAssertEqual(relays.count, RelayDefaults.urls.count + 1)
    XCTAssertEqual(
      Set(relays.map(\.url)),
      Set(RelayDefaults.urls).union(["wss://relay.example.com"])
    )
    XCTAssertTrue(relays.allSatisfy(\.isEnabled))
    XCTAssertEqual(
      Set(session.configuredRelays.map(\.url)),
      Set(RelayDefaults.urls).union(["wss://relay.example.com"])
    )

    session.addRelay(url: "wss://relay.example.com/")
    XCTAssertEqual(session.composeError, "that relay is already in your list.")
    relays = try fetchPersistedRelays(in: container.mainContext)
    XCTAssertEqual(relays.count, RelayDefaults.urls.count + 1)
  }

  func testRelayMutationsMaterializeDefaultsAndPreserveCustomEmptyState() async throws {
    let (session, container) = try makeSession()

    await session.boot()

    let firstRelay = try XCTUnwrap(session.configuredRelays.first)
    session.toggleRelay(firstRelay)
    var relays = try fetchPersistedRelays(in: container.mainContext)
    XCTAssertEqual(relays.count, RelayDefaults.urls.count)
    XCTAssertFalse(relays.contains(where: { $0.url == firstRelay.url && $0.isEnabled }))

    for relay in session.configuredRelays {
      session.removeRelay(relay)
    }

    relays = try fetchPersistedRelays(in: container.mainContext)
    XCTAssertTrue(relays.isEmpty)
    XCTAssertTrue(session.configuredRelays.isEmpty)
  }

  func testResetDefaultRelaysReturnsToVirtualDefaults() async throws {
    let (session, container) = try makeSession()

    await session.boot()
    session.addRelay(url: "wss://custom.example.com")
    var relays = try fetchPersistedRelays(in: container.mainContext)
    XCTAssertEqual(relays.count, RelayDefaults.urls.count + 1)

    session.resetDefaultRelays()
    relays = try fetchPersistedRelays(in: container.mainContext)

    XCTAssertTrue(relays.isEmpty)
    XCTAssertEqual(session.configuredRelays.map(\.url), RelayDefaults.urls)
  }

  func testBackgroundClearsRuntimeRelayStateBeforeForegroundRebuild() async throws {
    var startCount = 0
    var testingOverrides = AppSession.TestingOverrides()
    testingOverrides.disableNostrStartup = false
    testingOverrides.skipNostrNetworkStartup = true
    testingOverrides.onNostrStart = {
      startCount += 1
    }
    let (session, container) = try makeSession(testingOverrides: testingOverrides)
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    await session.boot()

    let initialStartupDeadline = Date(timeIntervalSinceNow: 0.2)
    while startCount < 1, Date() < initialStartupDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(startCount, 1)

    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    XCTAssertEqual(session.relayStatus(for: relay), .connected)

    session.handleAppDidLeaveForeground()
    XCTAssertEqual(session.relayStatus(for: relay), .disconnected)

    session.handleAppDidBecomeActive()

    let restartDeadline = Date(timeIntervalSinceNow: 0.2)
    while startCount < 2, Date() < restartDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertGreaterThanOrEqual(startCount, 2)
    XCTAssertEqual(session.relayStatus(for: relay), .disconnected)
  }

  func testForegroundStartupOnlyStartsOncePerForegroundEntryWhenNoRelayBecomesHealthy()
    async throws {
    var startCount = 0
    var testingOverrides = AppSession.TestingOverrides()
    testingOverrides.disableNostrStartup = false
    testingOverrides.skipNostrNetworkStartup = true
    testingOverrides.onNostrStart = {
      startCount += 1
    }
    let (session, container) = try makeSession(testingOverrides: testingOverrides)
    try session.identityService.createNewIdentity()

    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    await session.boot()

    let startupDeadline = Date(timeIntervalSinceNow: 0.2)
    while startCount < 1, Date() < startupDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(startCount, 1)
    XCTAssertEqual(session.relayStatus(for: relay), .disconnected)

    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(startCount, 1)

    session.handleAppDidLeaveForeground()

    let stableStartCount = startCount
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(startCount, stableStartCount)

    session.handleAppDidBecomeActive()

    let resumedStartupDeadline = Date(timeIntervalSinceNow: 0.2)
    while startCount == stableStartCount, Date() < resumedStartupDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(startCount, stableStartCount + 1)
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(startCount, stableStartCount + 1)
  }

  func testPushConversationNavigationConsumesTrimmedConversationIDIntoSessionRequest() throws {
    let (session, _) = try makeSession()
    let rawConversationID = "  push-session  "
    PushNotificationService.shared.enqueueConversationNavigation(to: rawConversationID)
    defer { _ = PushNotificationService.shared.consumePendingConversationID() }

    guard let conversationID = PushNotificationService.shared.consumePendingConversationID() else {
      XCTFail("expected pending conversation id")
      return
    }
    session.requestSessionNavigation(to: conversationID)

    XCTAssertEqual(session.pendingSessionNavigationRequest?.sessionID, "push-session")
    XCTAssertNil(PushNotificationService.shared.pendingConversationID)
  }

  func testPassiveOfflineToastDoesNotLoopAcrossForegroundRelayFlaps() throws {
    let (session, container) = try makeSession(passiveOfflineToastGraceInterval: 0.01)
    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.beginForegroundCycleForTesting()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped"
    )

    let firstToastDeadline = Date(timeIntervalSinceNow: 0.2)
    while session.composeError != "you're offline. waiting for a relay connection.",
      Date() < firstToastDeadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    XCTAssertEqual(session.composeError, "you're offline. waiting for a relay connection.")

    session.composeError = nil
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped again"
    )

    let secondToastDeadline = Date(timeIntervalSinceNow: 0.2)
    while session.composeError != nil, Date() < secondToastDeadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    XCTAssertNil(session.composeError)
  }

  func testPassiveOfflineToastRearmsOnNextForegroundCycle() throws {
    let (session, container) = try makeSession(passiveOfflineToastGraceInterval: 0.01)
    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.beginForegroundCycleForTesting()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped"
    )

    let firstToastDeadline = Date(timeIntervalSinceNow: 0.2)
    while session.composeError != "you're offline. waiting for a relay connection.",
      Date() < firstToastDeadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(session.composeError, "you're offline. waiting for a relay connection.")

    session.composeError = nil
    session.beginForegroundCycleForTesting()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped after reopen"
    )

    let secondToastDeadline = Date(timeIntervalSinceNow: 0.2)
    while session.composeError != "you're offline. waiting for a relay connection.",
      Date() < secondToastDeadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    XCTAssertEqual(session.composeError, "you're offline. waiting for a relay connection.")
  }

  func testPassiveOfflineToastWaitsThroughInitialForegroundReconnectGrace() throws {
    let (session, container) = try makeSession(passiveOfflineToastGraceInterval: 0.05)
    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.beginForegroundCycleForTesting()
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: relay.url,
      status: .failed,
      message: "relay dropped during reconnect"
    )

    XCTAssertNil(session.composeError)

    let toastDeadline = Date(timeIntervalSinceNow: 0.2)
    while session.composeError != "you're offline. waiting for a relay connection.",
      Date() < toastDeadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    XCTAssertEqual(session.composeError, "you're offline. waiting for a relay connection.")
  }

  func testForegroundCycleClearsStaleOfflineToast() throws {
    let (session, container) = try makeSession(passiveOfflineToastGraceInterval: 0.01)
    _ = container

    session.composeError = "you're offline. waiting for a relay connection."

    session.beginForegroundCycleForTesting()

    XCTAssertNil(session.composeError)
  }
}

@MainActor
final class NostrDMServiceTests: XCTestCase {
  func testLateRelayConnectAfterCompletedBackfillResetsCoverage() {
    let service = NostrDMService()
    service.seedBackfillCoverageForTesting(
      completedRelayURLs: ["wss://relay-a.example.com"],
      hasActiveBackfill: false,
      isCompleted: true
    )

    service.simulateLateRelayConnectionForTesting("wss://relay-b.example.com")

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 0)
    XCTAssertTrue(service.testingCompletedBackfillRelayURLs.isEmpty)
    XCTAssertTrue(service.testingCurrentBackfillRelayURLs.isEmpty)
    XCTAssertEqual(service.testingActiveBackfillCount, 0)
  }

  func testCoveredRelayConnectDoesNotResetCompletedBackfillCoverage() {
    let service = NostrDMService()
    service.seedBackfillCoverageForTesting(
      completedRelayURLs: ["wss://relay-a.example.com"],
      hasActiveBackfill: false,
      isCompleted: true
    )

    service.simulateLateRelayConnectionForTesting("wss://relay-a.example.com")

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 2)
    XCTAssertEqual(service.testingCompletedBackfillRelayURLs, ["wss://relay-a.example.com"])
  }

  func testLateRelayConnectDuringActiveBackfillResetsInFlightCoverage() {
    let service = NostrDMService()
    service.seedBackfillCoverageForTesting(
      activeRelayURLs: ["wss://relay-a.example.com"],
      hasActiveBackfill: true,
      isCompleted: false
    )

    service.simulateLateRelayConnectionForTesting("wss://relay-b.example.com")

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 0)
    XCTAssertEqual(service.testingActiveBackfillCount, 0)
    XCTAssertTrue(service.testingCurrentBackfillRelayURLs.isEmpty)
  }

  func testBackfillCoverageRefreshesAfterInitialCompletionWasAlreadyNotified() {
    let service = NostrDMService()

    service.simulateBackfillCoverageFinalizationForTesting(
      relayURLs: ["wss://relay-b.example.com"],
      initialCompletionAlreadyNotified: true
    )

    XCTAssertEqual(service.testingCompletedBackfillKindCount, 2)
    XCTAssertEqual(service.testingCompletedBackfillRelayURLs, ["wss://relay-b.example.com"])
    XCTAssertTrue(service.testingCurrentBackfillRelayURLs.isEmpty)
  }
}
