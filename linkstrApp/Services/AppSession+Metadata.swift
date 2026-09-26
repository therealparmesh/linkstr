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

    do {
      let normalizedProfileName = try NostrProfileMetadata.validatedOwnChosenName(profileName)
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds)
      guard !Task.isCancelled, identityService.pubkeyHex == ownerPubkey else { return false }
      let sourceService = nostrService
      let timestamp = try await nextPublicationTimestamp(
        after: latestAppliedProfileMetadataCreatedAt, subject: "profile",
        publicationOverridden: testingOverrides.publishRelayEvent != nil)
      guard !Task.isCancelled, identityService.pubkeyHex == ownerPubkey, nostrService === sourceService
      else { return false }
      let content = try NostrProfileMetadata.mergedContent(
        existingContent: currentProfileMetadataContent, chosenName: normalizedProfileName)
      let event = try NostrEvent.Builder<NostrEvent>(kind: .metadata)
        .createdAt(timestamp).content(content).build(signedBy: keypair)
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishEventAwaitingRelayAcceptance(event)
      }
      guard !Task.isCancelled, identityService.pubkeyHex == ownerPubkey, nostrService === sourceService
      else { return false }
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
      guard identityService.pubkeyHex == ownerPubkey, !Task.isCancelled else { return false }
      profileNameErrorMessage = composeError
      return false
    } catch {
      guard identityService.pubkeyHex == ownerPubkey, !Task.isCancelled else { return false }
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
      isProcessingMetadataQueue = false
    }
  }

  func processMetadataQueueIfNeeded() {
    guard !isProcessingMetadataQueue else { return }
    isProcessingMetadataQueue = true
    let generation = metadataRefreshQueueGeneration

    Task { @MainActor in
      var hasPendingSave = false
      while generation == metadataRefreshQueueGeneration,
        pendingMetadataRefreshHead < pendingMetadataRefreshes.count {
        let request = pendingMetadataRefreshes[pendingMetadataRefreshHead]
        pendingMetadataRefreshHead += 1
        activeMetadataRefreshStorageID = request.storageID

        do {
          guard let message = try messageStore.message(storageID: request.storageID) else {
            enqueuedMetadataStorageIDs.remove(request.storageID)
            activeMetadataRefreshStorageID = nil
            continue
          }
          let didChange = try await refreshMetadata(for: message)
          if didChange { hasPendingSave = true }
        } catch {
          report(error: error)
        }
        enqueuedMetadataStorageIDs.remove(request.storageID)
        activeMetadataRefreshStorageID = nil
      }

      if hasPendingSave {
        try? modelContext.save()
      }

      if generation == metadataRefreshQueueGeneration {
        pendingMetadataRefreshes.removeAll(keepingCapacity: true)
        pendingMetadataRefreshHead = 0
      }
      isProcessingMetadataQueue = false
      if generation != metadataRefreshQueueGeneration, !pendingMetadataRefreshes.isEmpty {
        processMetadataQueueIfNeeded()
      }
    }
  }

  func refreshMetadata(for message: SessionMessageEntity, force: Bool = false) async throws
    -> Bool {
    guard let url = message.url else { return false }
    guard force || needsMetadataRefresh(message) else {
      metadataRefreshRetryAfterByStorageID.removeValue(forKey: message.storageID)
      return false
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
      let message = try messageStore.message(storageID: storageID) else { return false }
    defer { updateMetadataRefreshCooldown(for: message) }
    guard let preview else { return false }

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

    guard resolvedTitle != currentTitle || resolvedThumbnail != currentThumbnail else {
      return false
    }

    try message.setMetadata(title: resolvedTitle, thumbnailURL: resolvedThumbnail)
    return true
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
  func refreshPostMetadata(_ message: SessionMessageEntity) async -> Bool {
    let owner = message.ownerPubkey
    let storageID = message.storageID
    guard identityService.pubkeyHex == owner else { return false }
    do {
      if let urlString = message.url, let url = URL(string: urlString) {
        await invalidateTransientMediaCaches(for: url)
      }
      guard !Task.isCancelled, identityService.pubkeyHex == owner,
        let message = try messageStore.message(storageID: storageID) else { return false }
      let didRefreshMetadata = try await refreshMetadata(for: message, force: true)
      guard !Task.isCancelled, identityService.pubkeyHex == owner else { return false }
      if didRefreshMetadata {
        try modelContext.save()
      }
      composeError = nil
      return didRefreshMetadata
    } catch {
      guard !Task.isCancelled, identityService.pubkeyHex == owner else { return false }
      report(error: error)
      return false
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
