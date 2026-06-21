import Foundation
import NostrSDK

// MARK: - Account Management

extension AppSession {
  func createAccount() {
    guard identityService.keypair == nil else {
      refreshIdentityState()
      return
    }

    do {
      try identityService.createNewIdentity()
      pendingCreatedAccountNsec = try identityService.revealNsec()
      refreshIdentityState()
      profileNameErrorMessage = nil
      composeError = nil
      scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
    } catch {
      pendingCreatedAccountNsec = nil
      composeError = error.localizedDescription
    }
  }

  func completePendingAccountCreation() {
    pendingCreatedAccountNsec = nil
    profileNameErrorMessage = nil
  }

  @discardableResult
  func completePendingAccountCreation(
    profileName: String?,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    let normalizedProfileName = NostrProfileMetadata.normalizedChosenName(profileName)
    guard normalizedProfileName != nil else {
      completePendingAccountCreation()
      return true
    }

    guard
      await updateOwnProfileName(
        normalizedProfileName,
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }

    completePendingAccountCreation()
    return true
  }

  func importNsec(_ nsec: String) {
    do {
      try identityService.importNsec(nsec)
      pendingCreatedAccountNsec = nil
      refreshIdentityState()
      profileNameErrorMessage = nil
      composeError = nil
      scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
    } catch {
      composeError = error.localizedDescription
    }
  }

  func logOut(clearLocalData: Bool) {
    let ownerPubkey = identityService.pubkeyHex
    let keypair = identityService.keypair
    let deviceToken = PushNotificationService.shared.deviceTokenHex
    schedulePushDeviceUnregistration(deviceToken: deviceToken, keypair: keypair)
    resetRuntimeSessionState()

    do {
      try identityService.clearIdentity()
    } catch {
      composeError = error.localizedDescription
      return
    }
    handleIdentityCleared()

    if let ownerPubkey, clearLocalData {
      do {
        try clearLocalAccountData(ownerPubkey: ownerPubkey)
      } catch {
        composeError =
          "signed out, but some local data could not be removed. \(error.localizedDescription)"
        return
      }
    }

    composeError = nil
  }

  @discardableResult
  func deleteAccountAwaitingRelay(
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this account."
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishFollowListAwaitingRelayAcceptance(followedPubkeyHexes: [])
        _ = try await publishEventAwaitingRelayAcceptance(
          makeVanishEvent(
            relayURLs: try relayStore.fetchRelays().filter(\.isEnabled).map(\.url),
            signedBy: keypair
          )
        )
      }
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    let deviceToken = PushNotificationService.shared.deviceTokenHex
    schedulePushDeviceUnregistration(deviceToken: deviceToken, keypair: keypair)
    resetRuntimeSessionState()

    do {
      try identityService.clearIdentity()
    } catch {
      composeError = error.localizedDescription
      return false
    }
    handleIdentityCleared()
    do {
      try clearLocalAccountData(ownerPubkey: ownerPubkey)
    } catch {
      composeError =
        "account deletion finished, but some local data could not be removed. \(error.localizedDescription)"
      return false
    }
    composeError = nil
    return true
  }

  func clearLocalAccountData(ownerPubkey: String) throws {
    if let clearLocalAccountDataOverride = testingOverrides.clearLocalAccountData {
      try clearLocalAccountDataOverride(ownerPubkey)
      return
    }

    var failures: [String] = []

    do {
      try messageStore.clearAllSessionData(ownerPubkey: ownerPubkey)
      ThumbnailImageCache.shared.clear()
    } catch {
      failures.append("couldn't remove local sessions and posts.")
    }

    do {
      try contactStore.clearAllContacts(ownerPubkey: ownerPubkey)
    } catch {
      failures.append("couldn't remove local contacts.")
    }

    do {
      try LocalDataCrypto.shared.clearKey(ownerPubkey: ownerPubkey)
    } catch {
      failures.append(error.localizedDescription)
    }

    do {
      try accountStateStore.deleteAccountState(ownerPubkey: ownerPubkey)
    } catch {
      failures.append("couldn't remove local account state.")
    }

    if !failures.isEmpty {
      throw LocalAccountCleanupError(failures: failures)
    }
  }
}

// MARK: - Misc Actions

extension AppSession {
  func markRootPostRead(postID: String) {
    guard let myPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.markRootPostRead(postID: postID, ownerPubkey: myPubkey, myPubkey: myPubkey)
    } catch {
      report(error: error)
    }
  }

  func clearPendingSessionNavigationRequest() {
    pendingSessionNavigationRequest = nil
  }

  func clearCachedMedia() {
    do {
      try messageStore.clearCachedMedia()
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func clearCachedMetadata() {
    do {
      try messageStore.clearCachedMetadata()
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func clearableCachedMediaBytes() -> Int64 {
    clearableStorageUsage().cachedMediaBytes
  }

  func clearableMetadataBytes() -> Int64 {
    clearableStorageUsage().previewBytes
  }

  func clearableStorageUsage() -> ManagedStorageUsage {
    (try? messageStore.managedStorageUsage()) ?? .zero
  }
}
