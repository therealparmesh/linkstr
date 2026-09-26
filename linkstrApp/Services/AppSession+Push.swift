import Foundation
import NostrSDK
import SwiftData

// MARK: - Push Notification Management

extension AppSession {
  func resetPushSyncState() {
    pushStateSyncGeneration += 1
    pushStateSyncTask?.cancel()
    pushStateSyncTask = nil
    pushStateSyncRequested = false
    lastRegisteredPushDeviceSignature = nil
    lastSyncedPushArchiveState = nil
  }

  func shouldManagePushStateForCurrentProcess() -> Bool {
    if testingOverrides.registerPushDevice != nil
      || testingOverrides.syncArchiveState != nil
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
    guard identityService.keypair != nil else {
      resetPushSyncState()
      return
    }

    pushStateSyncRequested = true
    guard pushStateSyncTask == nil else { return }
    let generation = pushStateSyncGeneration
    pushStateSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.pushStateSyncGeneration == generation { self.pushStateSyncTask = nil }
      }
      while !Task.isCancelled, self.pushStateSyncGeneration == generation,
        self.pushStateSyncRequested,
        let keypair = self.identityService.keypair {
        self.pushStateSyncRequested = false
        do {
          try await self.syncPushState(signedBy: keypair, generation: generation)
        } catch {
          if !Task.isCancelled { NSLog("Push state sync failed: \(error.localizedDescription)") }
        }
      }
    }
  }

  private func syncPushState(signedBy keypair: Keypair, generation: Int) async throws {
    let owner = keypair.publicKey.hex
    let deviceToken = PushNotificationService.shared.deviceTokenHex
    let environment = PushNotificationService.shared.apnsEnvironment
    let deviceSignature = deviceToken.map { "\(owner)|\($0)|\(environment)" }
    if let deviceToken, lastRegisteredPushDeviceSignature != deviceSignature {
      try await registerPushDevice(
        PushDeviceRegistration(deviceToken: deviceToken, apnsEnvironment: environment),
        signedBy: keypair)
      guard !Task.isCancelled, pushStateSyncGeneration == generation,
        identityService.pubkeyHex == owner
      else { return }
      lastRegisteredPushDeviceSignature = deviceSignature
      lastSyncedPushArchiveState = nil
    }
    let state = try await pushArchiveState(keypair: keypair)
    try Task.checkCancellation()
    guard pushStateSyncGeneration == generation, identityService.pubkeyHex == owner else { return }
    guard
      lastSyncedPushArchiveState?.ownerPubkey != owner || lastSyncedPushArchiveState?.state != state
    else { return }
    let archivedIDs = Set(state.archivedConversationIDs)
    // Bounded requests stay below the push service's 64 KiB body limit for session IDs.
    let batchSize = 200
    for offset in stride(from: 0, to: state.knownConversationIDs.count, by: batchSize) {
      try Task.checkCancellation()
      guard pushStateSyncGeneration == generation, identityService.pubkeyHex == owner else { return }
      let knownIDs = Array(state.knownConversationIDs.dropFirst(offset).prefix(batchSize))
      try await syncArchiveState(
        PushArchiveState(
          archivedConversationIDs: knownIDs.filter { archivedIDs.contains($0) },
          knownConversationIDs: knownIDs), signedBy: keypair)
    }
    guard !Task.isCancelled, pushStateSyncGeneration == generation,
      identityService.pubkeyHex == owner
    else { return }
    lastSyncedPushArchiveState = (owner, state)
  }

  private func pushArchiveState(keypair: Keypair) async throws -> PushArchiveState {
    let owner = keypair.publicKey.hex
    var archivedByID: [String: Bool] = [:]
    let events = try privatePreferenceStore.records(ownerPubkey: owner).map { try $0.event() }
    for preference in try await nostrService.eventDecoder.preferences(from: events, keypair: keypair) {
      if case .archive(let sessionID, let archived) = preference {
        archivedByID[sessionID] = archived
      }
    }
    let deleted = try modelContext.fetch(
      FetchDescriptor<SessionDeletionTombstoneEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == owner
        }))
    for session in deleted { archivedByID[session.sessionID] = false }
    return PushArchiveState(
      archivedConversationIDs: archivedByID.filter(\.value).map(\.key).sorted(),
      knownConversationIDs: archivedByID.keys.sorted())
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

  private func syncArchiveState(_ state: PushArchiveState, signedBy keypair: Keypair)
    async throws {
    if let syncArchiveStateOverride = testingOverrides.syncArchiveState {
      try await syncArchiveStateOverride(state)
      return
    }
    try await PushAPIClient.shared.syncArchiveState(state, signedBy: keypair)
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
