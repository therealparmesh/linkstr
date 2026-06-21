import Foundation
import NostrSDK
import SwiftData

// MARK: - Boot & Lifecycle

extension AppSession {
  func boot() async {
    guard !isBooting, !didFinishBoot else { return }
    isBooting = true
    didFinishBoot = false
    bootStatusMessage = "loading account…"
    defer {
      isBooting = false
    }

    await retryIdentityLoadIfNeeded(
      maxAttempts: bootIdentityRetryAttemptCount,
      retryDelayNanoseconds: configuredIdentityRetryDelayNanoseconds
    )
    if !isRunningTests && !isEnvironmentFlagEnabled("LINKSTR_SKIP_NOTIFICATION_PROMPT") {
      PushNotificationService.shared.requestAuthorizationIfNeeded()
    }

    #if targetEnvironment(simulator)
      if isEnvironmentFlagEnabled("LINKSTR_SIM_BOOTSTRAP") {
        bootStatusMessage = "preparing simulator account…"
        bootstrapSimulatorIfNeeded()
        refreshIdentityState()
      }
    #endif

    do {
      bootStatusMessage = "preparing local data…"
      bootStatusMessage = "connecting relays…"
      try reloadRelayConfiguration()
      pruneRuntimeRelayStatusCache()
    } catch {
      composeError = error.localizedDescription
    }
    bootStatusMessage = "starting session…"
    didFinishBoot = true
    beginForegroundCycle()
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
  }

  func handleAppDidBecomeActive() {
    beginForegroundCycle()
    if !isRunningTests && !isEnvironmentFlagEnabled("LINKSTR_SKIP_NOTIFICATION_PROMPT") {
      PushNotificationService.shared.refreshRegistrationIfAuthorized()
    }
    guard didFinishBoot else { return }
    if identityService.keypair != nil {
      schedulePushStateSync()
    }
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
  }

  func handleAppDidLeaveForeground() {
    let relayURLs = enabledRelayURLsSnapshot()
    isForeground = false
    observedHealthyRelayThisForeground = false
    passiveOfflineToastGraceUntil = nil
    cancelPendingOfflineToastIfNeeded()
    cancelPendingNostrStartupIfNeeded()
    stopRelayRuntime()
    primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
  }

  func handleProtectedDataDidBecomeAvailable() {
    guard didFinishBoot, isForeground else { return }
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.protectedDataAttempts)
  }

  func handlePushDeviceTokenDidChange() {
    schedulePushStateSync()
  }

  func report(error: Error) {
    composeError = error.localizedDescription
  }

  func requestSessionNavigation(to sessionID: String) {
    let normalizedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedID.isEmpty else { return }
    pendingSessionNavigationRequest = SessionNavigationRequest(sessionID: normalizedID)
  }

  var shouldPresentComposeErrorToast: Bool {
    suppressedComposeErrorPresentationCount == 0
  }

  func performFormMutation(_ operation: () async -> Bool) async -> FormMutationResult {
    suppressedComposeErrorPresentationCount += 1
    defer { suppressedComposeErrorPresentationCount -= 1 }

    let didSucceed = await operation()
    let errorMessage = didSucceed ? nil : takeComposeError()
    return FormMutationResult(didSucceed: didSucceed, errorMessage: errorMessage)
  }

  func takeComposeError() -> String? {
    let message = composeError?.trimmingCharacters(in: .whitespacesAndNewlines)
    composeError = nil
    guard let message, !message.isEmpty else { return nil }
    return message
  }

  func clearProfileNameError() {
    profileNameErrorMessage = nil
  }
}

// MARK: - Session Lifecycle & Archive

extension AppSession {
  func canManageSession(for session: SessionEntity) -> Bool {
    guard let myPubkey = identityService.pubkeyHex else { return false }
    return session.createdByPubkey == myPubkey
  }

  func isCurrentUserActiveMember(of session: SessionEntity, at timestamp: Date = .now) -> Bool {
    isCurrentUserActiveMember(
      sessionID: session.sessionID,
      ownerPubkey: session.ownerPubkey,
      at: timestamp
    )
  }

  func isCurrentUserActiveMember(
    sessionID: String,
    ownerPubkey: String,
    at timestamp: Date = .now
  ) -> Bool {
    guard let myPubkey = identityService.pubkeyHex else { return false }
    do {
      return try messageStore.isMemberActive(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        memberPubkey: myPubkey,
        at: timestamp
      )
    } catch {
      return false
    }
  }

  func setSessionArchived(sessionID: String, archived: Bool) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.setSessionArchived(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        archived: archived
      )
      schedulePushStateSync()
    } catch {
      report(error: error)
    }
  }

  @discardableResult
  func applySessionSnapshotLocally(_ params: SessionSnapshotParams) throws -> SessionEntity? {
    let ownerPubkey = params.ownerPubkey
    let sessionID = params.sessionID
    let createdByPubkey = params.createdByPubkey
    let memberPubkeys = params.memberPubkeys
    let updatedAt = params.updatedAt
    let eventID = params.eventID
    let isArchived = params.isArchived
    let normalizedName = normalizedSessionName(params.sessionName)
    let sessionEntity: SessionEntity

    if let existing = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
      let renameUpdatedAt = max(existing.updatedAt, updatedAt)
      sessionEntity = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: existing.name,
        createdByPubkey: existing.createdByPubkey,
        updatedAt: updatedAt,
        isArchived: isArchived ?? existing.isArchived
      )

      if let normalizedName, sessionEntity.name != normalizedName {
        try sessionEntity.updateName(normalizedName, updatedAt: renameUpdatedAt)
        try modelContext.save()
      }
    } else {
      guard let normalizedName else { return nil }
      sessionEntity = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: normalizedName,
        createdByPubkey: createdByPubkey,
        updatedAt: updatedAt,
        isArchived: isArchived
      )
    }

    try messageStore.applyMemberSnapshot(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      memberPubkeys: memberPubkeys,
      updatedAt: updatedAt,
      eventID: eventID
    )
    invalidateMemberIntervalCache(sessionID: sessionID)
    return sessionEntity
  }
}
