import Foundation
import NostrSDK

// MARK: - Relay Runtime & Configuration

extension AppSession {
  func replaceNostrService() {
    nostrService.stop()
    nostrService = NostrDMService()
  }

  func stopRelayRuntime() {
    clearRelayRuntimeTracking()
    replaceNostrService()
  }

  func beginForegroundCycle() {
    isForeground = true
    observedHealthyRelayThisForeground = false
    hasShownOfflineToastForCurrentOutage = false
    clearOfflineToastIfPresent()
    passiveOfflineToastGraceUntil = Date.now.addingTimeInterval(
      testingOverrides.passiveOfflineToastGraceInterval
        ?? AppSessionTimingDefaults.passiveOfflineToastGraceInterval
    )
    cancelPendingOfflineToastIfNeeded()
    cancelPendingNostrStartupIfNeeded()
  }

  func scheduleNostrStartup(maxAttempts: Int) {
    cancelPendingNostrStartupIfNeeded()
    guard didFinishBoot, isForeground else { return }

    nostrStartupGeneration += 1
    let generation = nostrStartupGeneration
    nostrStartupTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.nostrStartupGeneration == generation {
          self.nostrStartupTask = nil
        }
      }
      await self.retryIdentityLoadIfNeeded(
        maxAttempts: maxAttempts,
        retryDelayNanoseconds: self.configuredIdentityRetryDelayNanoseconds
      )
      guard !Task.isCancelled else { return }
      guard self.isForeground else { return }
      guard self.identityService.keypair != nil else { return }
      self.startNostrIfPossible(forceRestart: true)
    }
  }

  func startNostrIfPossible(forceRestart: Bool = false) {
    guard let keypair = identityService.keypair else { return }

    if forceRestart {
      stopRelayRuntime()
    }

    if shouldDisableNostrStartupForCurrentProcess() {
      handleNostrStartDisabled(forceRestart: forceRestart)
      return
    }

    if isRunningTests, testingOverrides.skipNostrNetworkStartup {
      handleTestSkipNetworkStartup(keypair: keypair, forceRestart: forceRestart)
      return
    }

    let relayURLs: [String]
    do {
      relayURLs = try relayStore.fetchRelays().filter(\.isEnabled).map(\.url)
    } catch {
      report(error: error)
      return
    }

    if forceRestart {
      primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
    }
    if relayURLs.isEmpty {
      handleEmptyRelayURLs(forceRestart: forceRestart)
      return
    }
    if composeError == noEnabledRelaysMessage {
      composeError = nil
    }
    relayRuntimeStatusByURL = relayRuntimeStatusByURL.filter { relayURLs.contains($0.key) }

    startNostrRuntime(
      keypair: keypair,
      relayURLs: relayURLs,
      onIncoming: makeIncomingHandler(),
      onRelayStatus: makeRelayStatusHandler(),
      onInitialBackfillComplete: { [weak self] in
        self?.finishInitialHistoricalRestore()
      },
      onFollowList: makeFollowListHandler(),
      onProfileMetadata: makeProfileMetadataHandler()
    )
  }

  func makeIncomingHandler() -> (ReceivedDirectMessage) -> Void {
    { [weak self] incoming in
      Task { @MainActor in
        self?.persistIncoming(incoming)
      }
    }
  }

  func makeRelayStatusHandler() -> (String, RelayHealthStatus, String?) -> Void {
    { [weak self] relayURL, status, message in
      Task { @MainActor in
        guard let self else { return }
        guard self.isForeground else { return }
        self.updateRuntimeRelayStatus(
          relayURL: relayURL,
          status: status,
          message: message
        )
        try? self.refreshRelayConnectivityAlert()
      }
    }
  }

  func makeFollowListHandler() -> (ReceivedFollowList) -> Void {
    { [weak self] followList in
      Task { @MainActor in
        self?.persistIncomingFollowList(followList)
      }
    }
  }

  func makeProfileMetadataHandler() -> (ReceivedProfileMetadata) -> Void {
    { [weak self] profileMetadata in
      Task { @MainActor in
        self?.persistIncomingProfileMetadata(profileMetadata)
      }
    }
  }

  private func handleEmptyRelayURLs(forceRestart: Bool) {
    if !forceRestart {
      stopRelayRuntime()
    }
    composeError = noEnabledRelaysMessage
    hasShownOfflineToastForCurrentOutage = false
  }

  private func handleNostrStartDisabled(forceRestart: Bool) {
    if !forceRestart {
      clearRelayRuntimeTracking()
    }
    testingOverrides.onNostrStart?()
  }

  private func handleTestSkipNetworkStartup(keypair: Keypair, forceRestart: Bool) {
    if forceRestart {
      let relayURLs = enabledRelayURLsSnapshot()
      primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
    } else {
      clearRelayRuntimeTracking()
    }
    startNostrRuntime(
      keypair: keypair,
      relayURLs: [],
      onIncoming: { _ in },
      onRelayStatus: { _, _, _ in },
      onInitialBackfillComplete: { [weak self] in
        self?.finishInitialHistoricalRestore()
      }
    )
  }

  func startNostrRuntime(
    keypair: Keypair,
    relayURLs: [String],
    onIncoming: @escaping (ReceivedDirectMessage) -> Void,
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void,
    onInitialBackfillComplete: (() -> Void)? = nil,
    onFollowList: ((ReceivedFollowList) -> Void)? = nil,
    onProfileMetadata: ((ReceivedProfileMetadata) -> Void)? = nil
  ) {
    testingOverrides.onNostrStart?()
    nostrService.start(
      keypair: keypair,
      relayURLs: relayURLs,
      onIncoming: onIncoming,
      onRelayStatus: onRelayStatus,
      onInitialBackfillComplete: onInitialBackfillComplete,
      onFollowList: onFollowList,
      onProfileMetadata: onProfileMetadata
    )
  }

  @discardableResult
  func addRelay(url: String) -> Bool {
    guard let parsedURL = normalizedRelayURL(from: url)
    else {
      composeError = "enter a valid relay url (ws:// or wss://)."
      return false
    }
    return performRelayMutation {
      try relayStore.addRelay(url: parsedURL)
    }
  }

  func removeRelay(_ relay: RelayEntity) {
    performRelayMutation {
      try relayStore.removeRelay(url: relay.url)
    }
  }

  func toggleRelay(_ relay: RelayEntity) {
    performRelayMutation {
      try relayStore.toggleRelay(url: relay.url)
    }
  }

  func restoreDefaultRelays() {
    performRelayMutation {
      try relayStore.restoreDefaultRelays()
    }
  }

  @discardableResult
  func performRelayMutation(_ mutation: () throws -> Void) -> Bool {
    do {
      try mutation()
      try reloadRelayConfiguration()
      composeError = nil
    } catch {
      report(error: error)
      return false
    }
    pruneRuntimeRelayStatusCache()
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
    return true
  }

  func normalizedRelayURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "ws" || scheme == "wss",
      let host = components.host,
      !host.isEmpty
    else {
      return nil
    }
    return components.url
  }
}
