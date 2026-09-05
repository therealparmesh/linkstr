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

    let normalizedProfileName: String?
    do {
      normalizedProfileName = try NostrProfileMetadata.validatedOwnChosenName(profileName)
    } catch {
      profileNameErrorMessage = error.localizedDescription
      composeError = error.localizedDescription
      return false
    }

    let metadataEvent: NostrEvent
    do {
      metadataEvent = try buildProfileMetadataEvent(
        normalizedProfileName: normalizedProfileName,
        keypair: keypair
      )
    } catch {
      profileNameErrorMessage = error.localizedDescription
      report(error: error)
      return false
    }

    return await publishProfileMetadata(
      metadataEvent: metadataEvent,
      ownerPubkey: ownerPubkey,
      normalizedProfileName: normalizedProfileName,
      timeoutSeconds: timeoutSeconds,
      pollIntervalSeconds: pollIntervalSeconds
    )
  }

  private func buildProfileMetadataEvent(
    normalizedProfileName: String?,
    keypair: Keypair
  ) throws -> NostrEvent {
    let metadataContent = try NostrProfileMetadata.mergedContent(
      existingContent: currentProfileMetadataContent,
      chosenName: normalizedProfileName
    )
    return try NostrEvent.Builder<NostrEvent>(kind: .metadata)
      .content(metadataContent)
      .build(signedBy: keypair)
  }

  private func publishProfileMetadata(
    metadataEvent: NostrEvent,
    ownerPubkey: String,
    normalizedProfileName: String?,
    timeoutSeconds: TimeInterval,
    pollIntervalSeconds: TimeInterval
  ) async -> Bool {
    let metadataContent = metadataEvent.content
    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishEventAwaitingRelayAcceptance(metadataEvent)
      }
      persistOwnProfileMetadataState(
        ownerPubkey: ownerPubkey,
        chosenName: normalizedProfileName,
        content: metadataContent,
        createdAt: metadataEvent.createdDate,
        eventID: metadataEvent.id
      )
      profileNameErrorMessage = nil
      composeError = nil
      return true
    } catch MutationPreparationError.relayBlocked {
      profileNameErrorMessage = composeError
      return false
    } catch {
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
    defer { updateMetadataRefreshCooldown(for: message) }

    let preview: LinkPreviewData?
    if let fetchLinkPreview = testingOverrides.fetchLinkPreview {
      preview = await fetchLinkPreview(url)
    } else {
      preview = await URLMetadataService.shared.fetchPreview(for: url)
    }
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
    do {
      if let urlString = message.url, let url = URL(string: urlString) {
        await invalidateTransientMediaCaches(for: url)
      }
      let didRefreshMetadata = try await refreshMetadata(for: message, force: true)
      if didRefreshMetadata {
        try modelContext.save()
      }
      composeError = nil
      return didRefreshMetadata
    } catch {
      report(error: error)
      return false
    }
  }

  // MARK: - Profile Metadata State

  func persistIncomingProfileMetadata(_ incoming: ReceivedProfileMetadata) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(incoming.eventID)

    if incoming.authorPubkey == ownerPubkey {
      guard
        NostrValueNormalizer.shouldApplyStateUpdate(
          currentUpdatedAt: latestAppliedProfileMetadataCreatedAt,
          currentEventID: latestAppliedProfileMetadataEventID,
          incomingUpdatedAt: incoming.createdAt,
          incomingEventID: normalizedEventID
        )
      else {
        return
      }

      persistOwnProfileMetadataState(
        ownerPubkey: ownerPubkey,
        chosenName: incoming.chosenName,
        content: incoming.rawContent,
        createdAt: incoming.createdAt,
        eventID: normalizedEventID
      )
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

  func persistOwnProfileMetadataState(
    ownerPubkey: String,
    chosenName: String?,
    content: String?,
    createdAt: Date,
    eventID: String?
  ) {
    let normalizedChosenName = NostrProfileMetadata.normalizedChosenName(chosenName)
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)
    currentProfileName = normalizedChosenName
    currentProfileMetadataContent = content?.trimmingCharacters(in: .whitespacesAndNewlines)
    latestAppliedProfileMetadataCreatedAt = createdAt
    latestAppliedProfileMetadataEventID = normalizedEventID

    do {
      try accountStateStore.setProfileMetadata(
        ownerPubkey: ownerPubkey,
        chosenName: normalizedChosenName,
        content: currentProfileMetadataContent,
        createdAt: createdAt,
        eventID: normalizedEventID
      )
    } catch {
      report(error: error)
    }
  }

}
