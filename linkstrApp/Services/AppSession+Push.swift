import Foundation
import NostrSDK

// MARK: - Push Notification Management

extension AppSession {
  func resetPushSyncState() {
    lastRegisteredPushDeviceSignature = nil
    lastArchivedConversationSyncSignature = nil
  }

  func shouldManagePushStateForCurrentProcess() -> Bool {
    if testingOverrides.registerPushDevice != nil
      || testingOverrides.syncArchivedConversationIDs != nil
      || testingOverrides.enqueuePushNotification != nil
      || testingOverrides.unregisterPushDevice != nil {
      return true
    }
    if isRunningTests {
      return false
    }
    return PushAPIClient.shared.isConfigured
  }

  func schedulePushStateSync() {
    guard shouldManagePushStateForCurrentProcess() else { return }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      resetPushSyncState()
      return
    }

    let deviceToken = PushNotificationService.shared.deviceTokenHex
    let apnsEnvironment = PushNotificationService.shared.apnsEnvironment
    let archivedConversationIDs =
      (try? messageStore.archivedConversationIDs(ownerPubkey: ownerPubkey)) ?? []
    let deviceSignature =
      deviceToken.map { "\(ownerPubkey)|\($0)|\(apnsEnvironment)" }
    let archiveSignature =
      "\(ownerPubkey)|\(archivedConversationIDs.sorted().joined(separator: ","))"

    Task { @MainActor in
      if let deviceToken, lastRegisteredPushDeviceSignature != deviceSignature {
        do {
          try await registerPushDevice(
            PushDeviceRegistration(
              deviceToken: deviceToken,
              apnsEnvironment: apnsEnvironment
            ),
            signedBy: keypair
          )
          lastRegisteredPushDeviceSignature = deviceSignature
        } catch {
          NSLog("Push device registration failed: \(error.localizedDescription)")
        }
      }

      guard lastArchivedConversationSyncSignature != archiveSignature else { return }
      do {
        try await syncArchivedConversationIDs(archivedConversationIDs, signedBy: keypair)
        lastArchivedConversationSyncSignature = archiveSignature
      } catch {
        NSLog("Push archive sync failed: \(error.localizedDescription)")
      }
    }
  }

  func schedulePushDeviceUnregistration(deviceToken: String?, keypair: Keypair?) {
    guard shouldManagePushStateForCurrentProcess() else { return }
    guard let deviceToken, let keypair else { return }
    Task { @MainActor in
      do {
        try await unregisterPushDevice(deviceToken: deviceToken, signedBy: keypair)
      } catch {
        NSLog("Push device unregistration failed: \(error.localizedDescription)")
      }
    }
  }

  func schedulePushEnqueue(_ request: PushEnqueueRequest) {
    guard shouldManagePushStateForCurrentProcess() else { return }
    guard let keypair = identityService.keypair else { return }
    Task { @MainActor in
      do {
        try await enqueuePushNotification(request, signedBy: keypair)
      } catch {
        NSLog("Push enqueue failed: \(error.localizedDescription)")
      }
    }
  }

  private func registerPushDevice(_ registration: PushDeviceRegistration, signedBy keypair: Keypair)
    async throws {
    if let registerPushDeviceOverride = testingOverrides.registerPushDevice {
      try await registerPushDeviceOverride(registration)
      return
    }
    try await PushAPIClient.shared.registerDevice(registration, signedBy: keypair)
  }

  private func unregisterPushDevice(deviceToken: String, signedBy keypair: Keypair) async throws {
    if let unregisterPushDeviceOverride = testingOverrides.unregisterPushDevice {
      try await unregisterPushDeviceOverride(deviceToken)
      return
    }
    try await PushAPIClient.shared.unregisterDevice(deviceToken: deviceToken, signedBy: keypair)
  }

  private func syncArchivedConversationIDs(_ conversationIDs: [String], signedBy keypair: Keypair)
    async throws {
    if let syncArchivedConversationIDsOverride = testingOverrides.syncArchivedConversationIDs {
      try await syncArchivedConversationIDsOverride(conversationIDs)
      return
    }
    try await PushAPIClient.shared.syncArchivedConversations(
      conversationIDs.sorted(),
      signedBy: keypair
    )
  }

  private func enqueuePushNotification(_ request: PushEnqueueRequest, signedBy keypair: Keypair)
    async throws {
    if let enqueuePushNotificationOverride = testingOverrides.enqueuePushNotification {
      try await enqueuePushNotificationOverride(request)
      return
    }
    try await PushAPIClient.shared.enqueuePush(request, signedBy: keypair)
  }
}
