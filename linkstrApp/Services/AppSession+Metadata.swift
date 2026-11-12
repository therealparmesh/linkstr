import Foundation
import NostrSDK
import SwiftData

// MARK: - Own Profile & Link Metadata

extension AppSession {
  @discardableResult
  func updateOwnProfileName(
    _ profileName: String?,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      let message = "you're signed out. sign in to manage your profile."
      profileNameErrorMessage = message
      composeError = message
      return false
    }

    let sourceService = nostrService
    do {
      let normalizedProfileName = try NostrProfileMetadata.validatedOwnChosenName(profileName)
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds)
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
      let timestamp = try await nextPublicationTimestamp(
        after: latestAppliedProfileMetadataCreatedAt, subject: "profile",
        publicationOverridden: testingOverrides.publishRelayEvent != nil)
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
      let content = try NostrProfileMetadata.mergedContent(
        existingContent: currentProfileMetadataContent, chosenName: normalizedProfileName)
      let event = try NostrEvent.Builder<NostrEvent>(kind: .metadata)
        .createdAt(timestamp).content(content).build(signedBy: keypair)
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishEventAwaitingRelayAcceptance(event)
      }
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
      guard event.id == latestAppliedProfileMetadataEventID
        || shouldApplyOwnProfileMetadata(createdAt: event.createdDate, eventID: event.id) else {
        throw NostrServiceError.publishRejected("profile changed on another device. try again.")
      }
      try persistOwnProfileMetadataState(
        ownerPubkey: ownerPubkey, chosenName: normalizedProfileName, content: content,
        createdAt: event.createdDate, eventID: event.id)
      profileNameErrorMessage = nil
      composeError = nil
      return true
    } catch MutationPreparationError.relayBlocked {
      guard identityService.pubkeyHex == ownerPubkey, nostrService === sourceService,
        !Task.isCancelled else { return false }
      profileNameErrorMessage = composeError
      return false
    } catch {
      guard identityService.pubkeyHex == ownerPubkey, nostrService === sourceService,
        !Task.isCancelled, !(error is CancellationError) else { return false }
      profileNameErrorMessage = error.localizedDescription
      report(error: error)
      return false
    }
  }

  // MARK: - Link Metadata Queue

  func enqueueMetadataRefresh(for message: SessionMessageEntity) {
    guard shouldFetchLinkMetadataForCurrentProcess() else { return }
    guard message.kind == .root else { return }
    guard message.url != nil else { return }

    let storageID = message.storageID
    guard needsMetadataRefresh(message) else {
      metadataRefreshRetryAfterByStorageID.removeValue(forKey: storageID)
      return
    }
    guard !isMetadataRefreshCoolingDown(storageID: storageID) else { return }
    guard !enqueuedMetadataStorageIDs.contains(storageID) else { return }
    enqueuedMetadataStorageIDs.insert(storageID)
    pendingMetadataRefreshes.append(PendingMetadataRefresh(storageID: storageID))
    processMetadataQueueIfNeeded()
  }

  func refreshMetadataForVisiblePostIfNeeded(_ message: SessionMessageEntity) {
    enqueueMetadataRefresh(for: message)
  }

  func cancelPendingMetadataRefreshesForHiddenSession() {
    metadataRefreshQueueGeneration += 1
    pendingMetadataRefreshes.removeAll(keepingCapacity: true)
    pendingMetadataRefreshHead = 0
    if let activeMetadataRefreshStorageID {
      enqueuedMetadataStorageIDs = [activeMetadataRefreshStorageID]
    } else {
      enqueuedMetadataStorageIDs.removeAll()
      metadataRefreshTask?.cancel()
      metadataRefreshTask = nil
    }
  }

  func processMetadataQueueIfNeeded() {
    guard metadataRefreshTask == nil else { return }
    let generation = metadataRefreshQueueGeneration

    metadataRefreshTask = Task { @MainActor in
      var hasPendingSave = false
      while generation == metadataRefreshQueueGeneration,
        pendingMetadataRefreshHead < pendingMetadataRefreshes.count {
        let request = pendingMetadataRefreshes[pendingMetadataRefreshHead]
        pendingMetadataRefreshHead += 1
        activeMetadataRefreshStorageID = request.storageID

        let didUpdate = await refreshQueuedMetadata(storageID: request.storageID)
        guard !Task.isCancelled else { return }
        hasPendingSave = hasPendingSave || didUpdate
        enqueuedMetadataStorageIDs.remove(request.storageID)
        activeMetadataRefreshStorageID = nil
      }

      guard !Task.isCancelled else { return }
      if hasPendingSave {
        try? modelContext.save()
      }

      if generation == metadataRefreshQueueGeneration {
        pendingMetadataRefreshes.removeAll(keepingCapacity: true)
        pendingMetadataRefreshHead = 0
      }
      metadataRefreshTask = nil
      if generation != metadataRefreshQueueGeneration, !pendingMetadataRefreshes.isEmpty {
        processMetadataQueueIfNeeded()
      }
    }
  }

  private func refreshQueuedMetadata(storageID: String) async -> Bool {
    do {
      guard let message = try messageStore.message(storageID: storageID) else { return false }
      return try await refreshMetadata(for: message) == .updated
    } catch {
      guard !Task.isCancelled else { return false }
      report(error: error)
      return false
    }
  }

  enum PostPreviewRefreshResult {
    case updated
    case unchanged
    case unavailable
    case interrupted
  }

  func refreshMetadata(for message: SessionMessageEntity, force: Bool = false) async throws
    -> PostPreviewRefreshResult {
    guard let url = message.url else { return .unavailable }
    guard force || needsMetadataRefresh(message) else {
      metadataRefreshRetryAfterByStorageID.removeValue(forKey: message.storageID)
      return .interrupted
    }
    let storageID = message.storageID
    let owner = message.ownerPubkey

    let preview: LinkPreviewData?
    if let fetchLinkPreview = testingOverrides.fetchLinkPreview {
      preview = await fetchLinkPreview(url)
    } else {
      preview = await URLMetadataService.shared.fetchPreview(for: url)
    }
    guard !Task.isCancelled, identityService.pubkeyHex == owner,
      let message = try messageStore.message(storageID: storageID) else { return .interrupted }
    defer { updateMetadataRefreshCooldown(for: message) }
    guard let preview else { return .unavailable }

    let currentTitle = LinkMetadataRefreshPolicy.normalizedTitle(message.metadataTitle)
    let previewTitle = LinkMetadataRefreshPolicy.normalizedTitle(preview.title)
    let resolvedTitle = previewTitle ?? currentTitle

    let currentThumbnail = ManagedLocalFileScope.shared.normalizedManagedPath(message.thumbnailURL)
    let previewThumbnail = ManagedLocalFileScope.shared.normalizedManagedPath(preview.thumbnailPath)
    let resolvedThumbnail: String?
    if let previewThumbnail {
      resolvedThumbnail = previewThumbnail
    } else if let currentThumbnail, FileManager.default.fileExists(atPath: currentThumbnail) {
      resolvedThumbnail = currentThumbnail
    } else {
      resolvedThumbnail = nil
    }

    // Fresh artwork can replace the file at the same path; notify thumbnail views to reload it.
    guard resolvedTitle != currentTitle || resolvedThumbnail != currentThumbnail || previewThumbnail != nil else {
      return .unchanged
    }

    try message.setMetadata(title: resolvedTitle, thumbnailURL: resolvedThumbnail)
    return .updated
  }

  private func isMetadataRefreshCoolingDown(storageID: String) -> Bool {
    guard let retryAfter = metadataRefreshRetryAfterByStorageID[storageID] else { return false }
    guard retryAfter > .now else {
      metadataRefreshRetryAfterByStorageID.removeValue(forKey: storageID)
      return false
    }
    return true
  }

  private func updateMetadataRefreshCooldown(for message: SessionMessageEntity) {
    let storageID = message.storageID
    guard needsMetadataRefresh(message) else {
      metadataRefreshRetryAfterByStorageID.removeValue(forKey: storageID)
      return
    }

    if metadataRefreshRetryAfterByStorageID[storageID] == nil,
      metadataRefreshRetryAfterByStorageID.count >= CacheLimits.maximumEntryCount,
      let earliestStorageID = metadataRefreshRetryAfterByStorageID.min(by: {
        $0.value < $1.value
      })?.key {
      metadataRefreshRetryAfterByStorageID.removeValue(forKey: earliestStorageID)
    }

    let retryInterval =
      testingOverrides.metadataRefreshRetryInterval
      ?? AppSessionTimingDefaults.metadataRefreshRetryInterval
    metadataRefreshRetryAfterByStorageID[storageID] = .now.addingTimeInterval(retryInterval)
  }

  func needsMetadataRefresh(_ message: SessionMessageEntity) -> Bool {
    guard message.kind == .root else { return false }
    guard message.url != nil else { return false }
    return LinkMetadataRefreshPolicy.needsRefresh(
      linkType: message.linkType,
      title: message.metadataTitle,
      thumbnailPath: ManagedLocalFileScope.shared.normalizedManagedPath(message.thumbnailURL)
    )
  }

  func invalidateTransientMediaCaches(for url: URL) async {
    await URLMetadataService.shared.invalidate(for: url)
    await URLCanonicalizationService.shared.invalidate(for: url)

    switch URLClassifier.classify(url) {
    case .twitter:
      await TwitterStatusResolutionService.shared.invalidate(for: url)
    case .instagram, .tiktok, .facebook:
      await SocialPostResolutionService.shared.invalidate(for: url)
    case .youtube, .rumble, .generic:
      break
    }
  }

  @discardableResult
  func refreshPostMetadata(_ message: SessionMessageEntity) async -> PostPreviewRefreshResult {
    let owner = message.ownerPubkey
    let storageID = message.storageID
    guard identityService.pubkeyHex == owner else { return .interrupted }
    do {
      if let urlString = message.url, let url = URL(string: urlString) {
        await invalidateTransientMediaCaches(for: url)
      }
      guard !Task.isCancelled, identityService.pubkeyHex == owner,
        let message = try messageStore.message(storageID: storageID) else { return .interrupted }
      let result = try await refreshMetadata(for: message, force: true)
      guard !Task.isCancelled, identityService.pubkeyHex == owner, result != .interrupted else {
        return .interrupted
      }
      if result == .updated {
        try modelContext.save()
      }
      composeError = nil
      return result
    } catch {
      guard !Task.isCancelled, identityService.pubkeyHex == owner else { return .interrupted }
      report(error: error)
      return .interrupted
    }
  }

  // MARK: - Profile Metadata State

  func persistIncomingProfileMetadata(_ incoming: ReceivedProfileMetadata) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(incoming.eventID)

    if incoming.authorPubkey == ownerPubkey {
      guard shouldApplyOwnProfileMetadata(createdAt: incoming.createdAt, eventID: normalizedEventID) else { return }
      do {
        try persistOwnProfileMetadataState(
          ownerPubkey: ownerPubkey, chosenName: incoming.chosenName, content: incoming.rawContent,
          createdAt: incoming.createdAt, eventID: normalizedEventID)
      } catch {
        reportIncomingPersistenceError(error)
      }
      return
    }

    updateRemoteProfileSnapshot(
      pubkeyHex: incoming.authorPubkey,
      chosenName: incoming.chosenName,
      createdAt: incoming.createdAt,
      eventID: normalizedEventID
    )
  }

  func resetProfileMetadataStateInMemory() {
    latestAppliedProfileMetadataCreatedAt = nil
    latestAppliedProfileMetadataEventID = nil
    currentProfileMetadataContent = nil
    currentProfileName = nil
  }

  func loadPersistedProfileMetadataState(ownerPubkey: String) {
    do {
      let profileMetadata = try accountStateStore.profileMetadata(ownerPubkey: ownerPubkey)
      currentProfileName = NostrProfileMetadata.normalizedChosenName(profileMetadata.chosenName)
      currentProfileMetadataContent = profileMetadata.content
      latestAppliedProfileMetadataCreatedAt = profileMetadata.createdAt
      latestAppliedProfileMetadataEventID = NostrValueNormalizer.normalizedEventID(
        profileMetadata.eventID
      )
    } catch {
      resetProfileMetadataStateInMemory()
    }
  }

  private func shouldApplyOwnProfileMetadata(createdAt: Date, eventID: String?) -> Bool {
    NostrValueNormalizer.shouldApplyReplaceableEvent(
      currentUpdatedAt: latestAppliedProfileMetadataCreatedAt,
      currentEventID: latestAppliedProfileMetadataEventID,
      incomingUpdatedAt: createdAt, incomingEventID: eventID)
  }

  private func persistOwnProfileMetadataState(
    ownerPubkey: String, chosenName: String?, content: String?, createdAt: Date, eventID: String?
  ) throws {
    let normalizedChosenName = NostrProfileMetadata.normalizedChosenName(chosenName)
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)
    let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedContent = trimmedContent?.isEmpty == true ? nil : trimmedContent
    try accountStateStore.setProfileMetadata(
      ownerPubkey: ownerPubkey, chosenName: normalizedChosenName, content: normalizedContent,
      createdAt: createdAt, eventID: normalizedEventID)
    currentProfileName = normalizedChosenName
    currentProfileMetadataContent = normalizedContent
    latestAppliedProfileMetadataCreatedAt = createdAt
    latestAppliedProfileMetadataEventID = normalizedEventID
  }
}
