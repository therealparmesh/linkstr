import Foundation
import NostrSDK
import SwiftData

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - Identity & Configuration Utilities

extension AppSession {
  var bootIdentityRetryAttemptCount: Int {
    isProtectedDataCurrentlyAvailable
      ? IdentityLoadRetryDefaults.bootAttempts
      : IdentityLoadRetryDefaults.protectedDataUnavailableBootAttempts
  }

  var configuredIdentityRetryDelayNanoseconds: UInt64 {
    testingOverrides.identityRetryDelayNanoseconds
      ?? AppSessionTimingDefaults.identityRetryDelayNanoseconds
  }

  var remoteProfileRetryNanoseconds: UInt64 {
    testingOverrides.remoteProfileLookupRetryNanoseconds
      ?? AppSessionTimingDefaults.remoteProfileLookupRetryNanoseconds
  }

  var isRunningTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  var isProtectedDataCurrentlyAvailable: Bool {
    #if canImport(UIKit)
      UIApplication.shared.isProtectedDataAvailable
    #else
      true
    #endif
  }

  func loadIdentityForCurrentProcess() -> IdentityService.LoadResult {
    if let loadIdentityOverride = testingOverrides.loadIdentity {
      return loadIdentityOverride(identityService)
    }
    return identityService.loadIdentity()
  }

  func retryIdentityLoadIfNeeded(
    maxAttempts: Int,
    retryDelayNanoseconds: UInt64
  ) async {
    guard hasIdentity == false else { return }
    guard !isRetryingIdentityLoad else { return }

    isRetryingIdentityLoad = true
    defer { isRetryingIdentityLoad = false }

    let attemptCount = max(1, maxAttempts)
    for attempt in 1...attemptCount {
      let loadResult = loadIdentityForCurrentProcess()
      refreshIdentityState()
      guard hasIdentity == false else { return }
      guard attempt < attemptCount else { return }

      switch loadResult {
      case .loaded:
        return
      case .missing, .failed:
        break
      }

      try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
    }
  }

  func makeLocalEventID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  func isEnvironmentFlagEnabled(_ key: String) -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env[key] == "1"
  }

  func shouldDisableNostrStartupForCurrentProcess() -> Bool {
    if let disableNostrStartupOverride = testingOverrides.disableNostrStartup {
      return disableNostrStartupOverride
    }

    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return false }
    return !isEnvironmentFlagEnabled("LINKSTR_ENABLE_NOSTR_IN_TESTS")
  }

  func isRelayPublicationEnabledForCurrentProcess() -> Bool {
    !shouldDisableNostrStartupForCurrentProcess()
  }

  func shouldFetchMetadataForCurrentProcess() -> Bool {
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return true }
    return isEnvironmentFlagEnabled("LINKSTR_ENABLE_METADATA_IN_TESTS")
  }

  func shouldFetchLinkMetadataForCurrentProcess() -> Bool {
    if testingOverrides.fetchLinkPreview != nil { return true }
    return shouldFetchMetadataForCurrentProcess()
  }
}

// MARK: - Identity State

extension AppSession {
  func refreshIdentityState() {
    hasIdentity = identityService.keypair != nil
    guard let ownerPubkey = identityService.pubkeyHex else {
      resetPushSyncState()
      resetFollowListStateInMemory()
      resetRemoteProfileStateInMemory()
      resetProfileMetadataStateInMemory()
      return
    }
    if testingOverrides.skipPersistedFollowListStateLoad {
      resetFollowListStateInMemory()
      resetRemoteProfileStateInMemory()
      resetProfileMetadataStateInMemory()
      return
    }
    loadPersistedFollowListState(ownerPubkey: ownerPubkey)
    resetRemoteProfileStateInMemory()
    loadPersistedProfileMetadataState(ownerPubkey: ownerPubkey)
    schedulePushStateSync()
  }

  func resetRuntimeSessionState() {
    let relayURLs = enabledRelayURLsSnapshot()
    stopRelayRuntime()
    primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
    cancelPendingOfflineToastIfNeeded()
    cancelPendingNostrStartupIfNeeded()
    pendingIncomingMessages.removeAll()
    isDrainingPendingIncomingMessages = false
    invalidateMemberIntervalCache()
    resetInitialHistoricalUnreadPolicy()
    pendingMetadataRefreshes.removeAll()
    pendingMetadataRefreshHead = 0
    enqueuedMetadataStorageIDs.removeAll()
    isProcessingMetadataQueue = false
    activeMetadataRefreshStorageID = nil
    metadataRefreshQueueGeneration = 0
    metadataRefreshRetryAfterByStorageID.removeAll()
    passiveOfflineToastGraceUntil = nil
    pendingSessionNavigationRequest = nil
    pendingCreatedAccountNsec = nil
  }

  func handleIdentityCleared() {
    resetPushSyncState()
    refreshIdentityState()
    resetFollowListStateInMemory()
    resetRemoteProfileStateInMemory()
    resetProfileMetadataStateInMemory()
    profileNameErrorMessage = nil
  }
}

// MARK: - Testing Hooks

#if DEBUG
  extension AppSession {
    func ingestForTesting(_ incoming: ReceivedDirectMessage) {
      persistIncoming(incoming)
    }

    var testingPendingMetadataRefreshCount: Int {
      pendingMetadataRefreshes.count
    }

    func simulateRuntimeRelayStatusForTesting(
      relayURL: String,
      status: RelayHealthStatus,
      message: String? = nil
    ) {
      updateRuntimeRelayStatus(relayURL: relayURL, status: status, message: message)
      try? refreshRelayConnectivityAlert()
    }

    func ingestFollowListForTesting(_ incoming: ReceivedFollowList) {
      persistIncomingFollowList(incoming)
    }

    func ingestProfileMetadataForTesting(_ incoming: ReceivedProfileMetadata) {
      persistIncomingProfileMetadata(incoming)
    }
  }
#endif

// MARK: - Simulator Bootstrap

#if targetEnvironment(simulator)
  extension AppSession {
    func bootstrapSimulatorIfNeeded() {
      if identityService.keypair == nil {
        try? identityService.createNewIdentity()
      }

      guard let ownerPubkey = identityService.pubkeyHex else { return }

      let contacts = fetchSimulatorContacts(ownerPubkey: ownerPubkey)
      let posts = fetchSimulatorPosts(ownerPubkey: ownerPubkey)

      guard
        let secondaryContact = resolveSimulatorContact(
          contacts: contacts,
          ownerPubkey: ownerPubkey
        )
      else { return }

      if posts.isEmpty {
        seedSimulatorSession(ownerPubkey: ownerPubkey, secondaryContact: secondaryContact)
      }

      try? modelContext.save()
    }

    private func fetchSimulatorContacts(ownerPubkey: String) -> [ContactEntity] {
      let contactsDescriptor = FetchDescriptor<ContactEntity>()
      return ((try? modelContext.fetch(contactsDescriptor)) ?? []).filter {
        $0.ownerPubkey == ownerPubkey
      }
    }

    private func fetchSimulatorPosts(ownerPubkey: String) -> [SessionMessageEntity] {
      ((try? modelContext.fetch(FetchDescriptor<SessionMessageEntity>())) ?? []).filter {
        $0.kind == .root && $0.ownerPubkey == ownerPubkey
      }
    }

    private func resolveSimulatorContact(
      contacts: [ContactEntity],
      ownerPubkey: String
    ) -> ContactEntity? {
      if let firstContact = contacts.first {
        return firstContact
      }
      let secondaryKeypair = Keypair()
      let pubkeyHex =
        secondaryKeypair?.publicKey.hex
        ?? "0000000000000000000000000000000000000000000000000000000000000001"
      let contact = try? ContactEntity(
        ownerPubkey: ownerPubkey,
        targetPubkey: pubkeyHex,
        alias: "secondary test contact"
      )
      guard let contact else { return nil }
      modelContext.insert(contact)
      return contact
    }

    private func seedSimulatorSession(ownerPubkey: String, secondaryContact: ContactEntity) {
      guard let myPubkey = identityService.pubkeyHex,
        PublicKey(hex: secondaryContact.targetPubkey) != nil
      else { return }

      let peerPubkey = secondaryContact.targetPubkey
      let sessionID = "sim-\(ownerPubkey.prefix(12))"
      let sessionName = "simulator session"
      let seededAt = Date.now
      _ = try? messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: sessionName,
        createdByPubkey: myPubkey,
        updatedAt: seededAt
      )
      try? messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkeys: [myPubkey, peerPubkey],
        updatedAt: seededAt
      )
      let sampleURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
      let sampleEventID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

      let post = try? SessionMessageEntity(
        eventID: sampleEventID,
        ownerPubkey: ownerPubkey,
        conversationID: sessionID,
        rootID: sampleEventID,
        kind: .root,
        senderPubkey: myPubkey,
        url: sampleURL,
        note: "seeded simulator post",
        timestamp: .now,
        readAt: .now,
        linkType: URLClassifier.classify(sampleURL),
        metadataTitle: "sample link"
      )
      if let post {
        modelContext.insert(post)
      }
    }
  }
#endif
