import Foundation

// MARK: - Relay Status & Connectivity

extension AppSession {
  func isRelayConnectionAlertMessage(_ message: String) -> Bool {
    message == noEnabledRelaysMessage
      || message == relayOfflineMessage
      || message == relayReadOnlyMessage
      || message == relaySendTimeoutMessage
      || message == NostrServiceError.publishTimedOut.localizedDescription
  }

  func relayConnectivityState(for enabledRelays: [RelayEntity]) -> RelayConnectivityState {
    guard !enabledRelays.isEmpty else { return .noEnabledRelays }

    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .connected }) {
      return .online
    }
    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .connecting }) {
      return .connecting
    }
    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .readOnly }) {
      return .readOnly
    }
    return .offline
  }

  func clearOfflineToastIfPresent() {
    if composeError == relayOfflineMessage {
      composeError = nil
    }
  }

  func cancelPendingOfflineToastIfNeeded() {
    pendingOfflineToastTask?.cancel()
    pendingOfflineToastTask = nil
  }

  func cancelPendingNostrStartupIfNeeded() {
    nostrStartupGeneration += 1
    nostrStartupTask?.cancel()
    nostrStartupTask = nil
  }

  func showOfflineToastForCurrentOutageIfNeeded() {
    guard observedHealthyRelayThisForeground else { return }
    guard !hasShownOfflineToastForCurrentOutage else { return }
    let now = Date.now
    if let passiveOfflineToastGraceUntil, now < passiveOfflineToastGraceUntil {
      scheduleOfflineToastReevaluation(at: passiveOfflineToastGraceUntil)
      return
    }
    cancelPendingOfflineToastIfNeeded()
    composeError = relayOfflineMessage
    hasShownOfflineToastForCurrentOutage = true
  }

  func scheduleOfflineToastReevaluation(at deadline: Date) {
    guard pendingOfflineToastTask == nil else { return }
    let delay = max(0, deadline.timeIntervalSinceNow)
    pendingOfflineToastTask = Task { [weak self] in
      if delay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        defer { self.pendingOfflineToastTask = nil }
        guard self.isForeground else { return }
        try? self.refreshRelayConnectivityAlert()
      }
    }
  }

  func clearRelaySendBlockingErrorIfPresent() {
    if composeError == relayOfflineMessage
      || composeError == noEnabledRelaysMessage
      || composeError == relayReadOnlyMessage {
      composeError = nil
    }
  }

  func relayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    if relay.isEnabled == false {
      return .disconnected
    }
    return effectiveRelayStatus(for: relay)
  }

  func relayErrorMessage(for relay: RelayEntity) -> String? {
    guard relay.isEnabled else { return nil }
    let trimmedRuntime =
      relayRuntimeStatusByURL[relay.url]?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    return trimmedRuntime.isEmpty ? nil : trimmedRuntime
  }

  func connectedRelayCount(for relays: [RelayEntity]) -> Int {
    relays.count { relay in
      relay.isEnabled
        && (relayStatus(for: relay) == .connected || relayStatus(for: relay) == .readOnly)
    }
  }

  func effectiveRelayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    relayRuntimeStatusByURL[relay.url]?.status ?? .disconnected
  }

  func updateRuntimeRelayStatus(
    relayURL: String,
    status: RelayHealthStatus,
    message: String?
  ) {
    if status == .connected || status == .readOnly {
      observedHealthyRelayThisForeground = true
      drainPendingIncomingMessagesIfNeeded()
      retryPendingRemoteProfileRequestsIfNeeded()
    }

    let now = Date()
    let normalizedMessage = normalizedRelayStatusMessage(message)
    if let existing = relayRuntimeStatusByURL[relayURL],
      existing.status == .connected || existing.status == .readOnly,
      status == .disconnected,
      normalizedMessage == nil,
      now.timeIntervalSince(existing.updatedAt)
        < AppSessionTimingDefaults.relayDisconnectGraceInterval {
      return
    }

    if let existing = relayRuntimeStatusByURL[relayURL],
      existing.status == status,
      existing.message == normalizedMessage {
      relayRuntimeStatusByURL[relayURL]?.updatedAt = now
      return
    }

    relayRuntimeStatusByURL[relayURL] = RelayRuntimeStatus(
      status: status,
      message: normalizedMessage,
      updatedAt: now
    )
  }

  func normalizedRelayStatusMessage(_ message: String?) -> String? {
    guard let message else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func enabledRelayURLsSnapshot() -> [String] {
    (try? relayStore.fetchRelays().filter(\.isEnabled).map(\.url)) ?? []
  }

  func reloadRelayConfiguration() throws {
    configuredRelays = try relayStore.fetchRelays()
  }

  func clearRelayRuntimeTracking() {
    relayRuntimeStatusByURL.removeAll()
  }

  func primeRelayRuntimeStatusForFreshStart(relayURLs: [String]) {
    guard !relayURLs.isEmpty else { return }
    let now = Date()
    relayRuntimeStatusByURL = Dictionary(
      uniqueKeysWithValues: relayURLs.map {
        (
          $0,
          RelayRuntimeStatus(
            status: .disconnected,
            message: nil,
            updatedAt: now
          )
        )
      }
    )
  }

  func pruneRuntimeRelayStatusCache() {
    let relays = (try? relayStore.fetchRelays()) ?? []
    let enabledURLs = Set(relays.filter(\.isEnabled).map(\.url))
    relayRuntimeStatusByURL = relayRuntimeStatusByURL.filter { enabledURLs.contains($0.key) }
  }

  func refreshRelayConnectivityAlert() throws {
    let enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    switch relayConnectivityState(for: enabledRelays) {
    case .online, .readOnly:
      cancelPendingOfflineToastIfNeeded()
      clearOfflineToastIfPresent()
    case .connecting:
      cancelPendingOfflineToastIfNeeded()
      return
    case .offline:
      showOfflineToastForCurrentOutageIfNeeded()
    case .noEnabledRelays:
      cancelPendingOfflineToastIfNeeded()
      return
    }
  }

  func relaySendWaitState() -> RelaySendWaitState {
    if shouldDisableNostrStartupForCurrentProcess() {
      return .ready
    }

    let enabledRelays: [RelayEntity]
    do {
      enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    } catch {
      return .blocked(message: error.localizedDescription)
    }

    switch relayConnectivityState(for: enabledRelays) {
    case .noEnabledRelays:
      if let hasConnectedRelaysOverride = testingOverrides.hasConnectedRelays,
        hasConnectedRelaysOverride() {
        return .ready
      }
      return .blocked(message: noEnabledRelaysMessage)
    case .readOnly:
      return .blocked(message: relayReadOnlyMessage)
    case .online:
      return .ready
    case .connecting, .offline:
      if let hasConnectedRelaysOverride = testingOverrides.hasConnectedRelays,
        hasConnectedRelaysOverride() {
        return .ready
      }
      return .waitingForConnection
    }
  }

  func awaitRelayReadyForSend(
    timeoutSeconds: TimeInterval,
    pollIntervalSeconds: TimeInterval
  ) async -> Bool {
    let timeout = max(0, timeoutSeconds)
    let pollInterval = max(0.05, pollIntervalSeconds)
    let deadline = Date.now.addingTimeInterval(timeout)

    while true {
      switch relaySendWaitState() {
      case .ready:
        clearRelaySendBlockingErrorIfPresent()
        return true
      case .blocked(let message):
        composeError = message
        hasShownOfflineToastForCurrentOutage = false
        return false
      case .waitingForConnection:
        if Date.now >= deadline {
          composeError = relaySendTimeoutMessage
          hasShownOfflineToastForCurrentOutage = false
          return false
        }

        if composeError == relayOfflineMessage {
          composeError = nil
        }
        startNostrIfPossible()

        let sleepNanoseconds = UInt64(pollInterval * 1_000_000_000)
        try? await Task.sleep(nanoseconds: sleepNanoseconds)
      }
    }
  }

  func prepareRelayMutationIfNeeded(
    timeoutSeconds: TimeInterval,
    pollIntervalSeconds: TimeInterval
  ) async throws {
    guard isRelayPublicationEnabledForCurrentProcess() else { return }
    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      throw MutationPreparationError.relayBlocked
    }
  }
}
