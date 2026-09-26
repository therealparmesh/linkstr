import Foundation
import NostrSDK

// MARK: - Relay Runtime & Configuration

extension AppSession {
  func replaceNostrService() {
    pauseRemoteProfileRequests()
    privatePreferenceSyncTask?.cancel()
    privatePreferenceSyncTask = nil
    nostrService.stop()
    nostrService = NostrDMService()
  }

  func stopRelayRuntime(preservingHistory: Bool = false) {
    clearRelayRuntimeTracking()
    if preservingHistory {
      pauseRemoteProfileRequests()
      privatePreferenceSyncTask?.cancel()
      privatePreferenceSyncTask = nil
      nostrService.stop(clearHistory: false)
    } else {
      replaceNostrService()
    }
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
      self.startNostrIfPossible()
    }
  }

  func startNostrIfPossible() {
    guard let keypair = identityService.keypair else { return }

    if shouldDisableNostrStartupForCurrentProcess() {
      handleNostrStartDisabled()
      return
    }

    if isRunningTests, testingOverrides.skipNostrNetworkStartup {
      handleTestSkipNetworkStartup(keypair: keypair)
      return
    }

    let relayURLs: [String]
    do {
      relayURLs = try relayStore.fetchRelays().filter(\.isEnabled).map(\.url)
    } catch {
      nostrService.finishFollowListQuery(unavailable: true)
      report(error: error)
      return
    }

    if relayURLs.isEmpty {
      handleEmptyRelayURLs()
      nostrService.finishFollowListQuery(unavailable: true)
      return
    }
    if composeError == noEnabledRelaysMessage {
      composeError = nil
    }
    if !nostrService.isConfigured(for: keypair, relayURLs: relayURLs) {
      stopRelayRuntime(preservingHistory: true)
      primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
    }

    startNostrRuntime(
      keypair: keypair,
      relayURLs: relayURLs,
      onIncoming: makeIncomingHandler(),
      onRelayStatus: makeRelayStatusHandler(),
      onInitialBackfillComplete: makeInitialBackfillCompleteHandler(),
      onFollowList: makeFollowListHandler(),
      onProfileMetadata: makeProfileMetadataHandler()
    )
  }

  func makeIncomingHandler() -> (ReceivedDirectMessage) -> Void {
    let sourceService = nostrService
    return { [weak self, weak sourceService] incoming in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      self.persistIncoming(incoming)
    }
  }

  func makeRelayStatusHandler() -> (String, RelayHealthStatus, String?) -> Void {
    let sourceService = nostrService
    return { [weak self, weak sourceService] relayURL, status, message in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      guard self.isForeground else { return }
      self.updateRuntimeRelayStatus(
        relayURL: relayURL,
        status: status,
        message: message
      )
      try? self.refreshRelayConnectivityAlert()
    }
  }

  func makeInitialBackfillCompleteHandler() -> () -> Void {
    let sourceService = nostrService
    return { [weak self, weak sourceService] in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      self.finishInitialHistoricalRestore()
    }
  }

  func makeFollowListHandler() -> (ReceivedFollowList) -> Void {
    let sourceService = nostrService
    return { [weak self, weak sourceService] followList in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      self.persistIncomingFollowList(followList)
    }
  }

  func makeProfileMetadataHandler() -> (ReceivedProfileMetadata) -> Void {
    let sourceService = nostrService
    return { [weak self, weak sourceService] profileMetadata in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      self.persistIncomingProfileMetadata(profileMetadata)
    }
  }

  private func handleEmptyRelayURLs() {
    stopRelayRuntime()
    composeError = noEnabledRelaysMessage
    hasShownOfflineToastForCurrentOutage = false
  }

  private func handleNostrStartDisabled() {
    nostrService.finishFollowListQuery(unavailable: true)
    clearRelayRuntimeTracking()
    testingOverrides.onNostrStart?()
  }

  private func handleTestSkipNetworkStartup(keypair: Keypair) {
    clearRelayRuntimeTracking()
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
    nostrService.contactDiscovery = contactDiscovery
    let sourceService = nostrService
    nostrService.onProfileLookupComplete = { [weak self, weak sourceService] requestID, completed in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      if completed { self.finishRemoteProfileLookup(requestID, completed: true) }
    }
    nostrService.onPrivatePreference = { [weak self, weak sourceService] event in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      await self.receivePrivatePreference(event)
    }
    nostrService.onPrivatePreferencesReady = { [weak self, weak sourceService] in
      guard let self, let sourceService, self.nostrService === sourceService else { return }
      await self.preparePrivatePreferenceBackup()
    }
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
