import Foundation
import SwiftData

// MARK: - SessionMessageStore Deletions & Storage

extension SessionMessageStore {
  @discardableResult
  func applySessionDeletion(
    ownerPubkey: String,
    sessionID: String,
    deletedByPubkey: String,
    updatedAt: Date,
    eventID: String
  ) throws -> Bool {
    guard let normalizedDeletedByPubkey = NostrValueNormalizer.normalizedPubkeyHex(deletedByPubkey)
    else {
      throw NostrServiceError.invalidPubkey
    }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID) ?? ""
    let storageID = SessionDeletionTombstoneEntity.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID
    )
    let descriptor = FetchDescriptor<SessionDeletionTombstoneEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )

    var didChange = false
    if let existing = try modelContext.fetch(descriptor).first {
      guard
        NostrValueNormalizer.shouldApplyStateUpdate(
          currentUpdatedAt: existing.updatedAt,
          currentEventID: existing.lastEventID,
          incomingUpdatedAt: updatedAt,
          incomingEventID: normalizedEventID
        )
      else {
        return false
      }
      existing.updatedAt = updatedAt
      existing.lastEventID = normalizedEventID
      didChange = true
    } else {
      let tombstone = try SessionDeletionTombstoneEntity(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        deletedByPubkey: normalizedDeletedByPubkey,
        updatedAt: updatedAt,
        eventID: normalizedEventID
      )
      modelContext.insert(tombstone)
      didChange = true
    }

    let storedFileURLs = try purgeSessionDataRecords(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      shouldSave: false
    )
    if didChange || !storedFileURLs.isEmpty {
      try modelContext.save()
    }
    removeManagedFiles(at: storedFileURLs)
    return didChange || !storedFileURLs.isEmpty
  }

  @discardableResult
  func applyRootDeletion(_ params: ApplyRootDeletionParams) throws -> Bool {
    guard
      let normalizedDeletedByPubkey = NostrValueNormalizer.normalizedPubkeyHex(
        params.deletedByPubkey)
    else {
      throw NostrServiceError.invalidPubkey
    }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(params.eventID) ?? ""

    var didChange = try upsertDeletionEntity(
      params: params,
      normalizedDeletedByPubkey: normalizedDeletedByPubkey,
      normalizedEventID: normalizedEventID
    )
    let storedFileURLs = try deleteMatchingRootMessages(
      ownerPubkey: params.ownerPubkey,
      sessionID: params.sessionID,
      rootID: params.rootID,
      deletedByPubkey: normalizedDeletedByPubkey,
      didChange: &didChange
    )
    try deleteReactionsForRoot(
      ownerPubkey: params.ownerPubkey,
      sessionID: params.sessionID,
      rootID: params.rootID,
      didChange: &didChange
    )

    if didChange {
      try modelContext.save()
    }
    removeManagedFiles(at: storedFileURLs)
    return didChange
  }

  private func upsertDeletionEntity(
    params: ApplyRootDeletionParams,
    normalizedDeletedByPubkey: String,
    normalizedEventID: String
  ) throws -> Bool {
    let deletionStorageID = SessionPostDeletionEntity.storageID(
      ownerPubkey: params.ownerPubkey,
      sessionID: params.sessionID,
      rootID: params.rootID,
      deletedByPubkey: normalizedDeletedByPubkey
    )
    let deletionDescriptor = FetchDescriptor<SessionPostDeletionEntity>(
      predicate: #Predicate { $0.storageID == deletionStorageID }
    )
    if let existingDeletion = try modelContext.fetch(deletionDescriptor).first {
      if NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: existingDeletion.updatedAt,
        currentEventID: existingDeletion.lastEventID,
        incomingUpdatedAt: params.updatedAt,
        incomingEventID: normalizedEventID
      ) {
        existingDeletion.updatedAt = params.updatedAt
        existingDeletion.lastEventID = normalizedEventID
        return true
      }
    } else {
      let deletion = try SessionPostDeletionEntity(
        ownerPubkey: params.ownerPubkey,
        sessionID: params.sessionID,
        rootID: params.rootID,
        deletedByPubkey: normalizedDeletedByPubkey,
        updatedAt: params.updatedAt,
        eventID: normalizedEventID
      )
      modelContext.insert(deletion)
      return true
    }
    return false
  }

  private func deleteMatchingRootMessages(
    ownerPubkey: String,
    sessionID: String,
    rootID: String,
    deletedByPubkey: String,
    didChange: inout Bool
  ) throws -> Set<URL> {
    let storedRoot = try rootPost(ownerPubkey: ownerPubkey, sessionID: sessionID, rootID: rootID)
    let deletedByHash = LocalDataCrypto.shared.digestHex(deletedByPubkey)
    let matchingRootMessages =
      storedRoot.map { $0.senderMatchesHash(deletedByHash) ? [$0] : [] } ?? []
    let storedFileURLs = managedStoredFileURLs(for: matchingRootMessages)
    if !matchingRootMessages.isEmpty {
      matchingRootMessages.forEach(modelContext.delete)
      didChange = true
    }
    return storedFileURLs
  }

  private func deleteReactionsForRoot(
    ownerPubkey: String,
    sessionID: String,
    rootID: String,
    didChange: inout Bool
  ) throws {
    let reactionDescriptor = FetchDescriptor<SessionReactionEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey
          && $0.sessionID == sessionID
          && $0.postID == rootID
      }
    )
    let reactions = try modelContext.fetch(reactionDescriptor)
    if !reactions.isEmpty {
      reactions.forEach(modelContext.delete)
      didChange = true
    }
  }

  func purgeSessionData(ownerPubkey: String, sessionID: String) throws {
    let storedFileURLs = try purgeSessionDataRecords(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      shouldSave: true
    )
    removeManagedFiles(at: storedFileURLs)
  }

  @discardableResult
  func purgeSessionDataRecords(
    ownerPubkey: String,
    sessionID: String,
    shouldSave: Bool
  ) throws -> Set<URL> {
    let messages = try modelContext.fetch(
      FetchDescriptor<SessionMessageEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.conversationID == sessionID }
      )
    )
    let sessions = try modelContext.fetch(
      FetchDescriptor<SessionEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
      )
    )
    let members = try modelContext.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
      )
    )
    let intervals = try modelContext.fetch(
      FetchDescriptor<SessionMemberIntervalEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
      )
    )
    let reactions = try modelContext.fetch(
      FetchDescriptor<SessionReactionEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
      )
    )
    let deletions = try modelContext.fetch(
      FetchDescriptor<SessionPostDeletionEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
      )
    )

    let didChange =
      !messages.isEmpty
      || !sessions.isEmpty
      || !members.isEmpty
      || !intervals.isEmpty
      || !reactions.isEmpty
      || !deletions.isEmpty
    guard didChange else { return [] }

    let storedFileURLs = managedStoredFileURLs(for: messages)
    messages.forEach(modelContext.delete)
    sessions.forEach(modelContext.delete)
    members.forEach(modelContext.delete)
    intervals.forEach(modelContext.delete)
    reactions.forEach(modelContext.delete)
    deletions.forEach(modelContext.delete)
    if shouldSave {
      try modelContext.save()
    }
    return storedFileURLs
  }

  func clearCachedMedia() throws {
    try clearCachedMedia(messages: storageMessages())
  }

  func clearCachedMetadata() throws {
    try clearCachedMetadata(messages: storageMessages())
  }

  func managedStorageUsage() throws -> ManagedStorageUsage {
    let messages = try storageMessages()
    return managedStorageUsage(messages: messages)
  }

  private func storageMessages() throws -> [SessionMessageEntity] {
    return try modelContext.fetch(FetchDescriptor<SessionMessageEntity>())
  }

  private func clearCachedMedia(messages: [SessionMessageEntity]) throws {
    var didChange = false
    for message in messages {
      if let cachedMediaURL = ManagedLocalFileScope.shared.managedFileURL(
        fromPath: message.cachedMediaPath) {
        try? FileManager.default.removeItem(at: cachedMediaURL)
      }

      let hadCachedMedia =
        message.cachedMediaPath != nil
        || message.cachedMediaSourceURL != nil
      guard hadCachedMedia else { continue }

      message.cachedMediaPath = nil
      message.cachedMediaSourceURL = nil
      didChange = true
    }
    if didChange {
      try modelContext.save()
    }
  }

  private func clearCachedMetadata(messages: [SessionMessageEntity]) throws {
    var didChange = false
    var clearedStorageIDs = Set<String>()
    var clearedThumbnailPaths = Set<String>()
    for message in messages {
      let currentThumbnailPath = ManagedLocalFileScope.shared.normalizedManagedPath(
        message.thumbnailURL)
      let hadCachedMetadata = message.metadataTitle != nil || currentThumbnailPath != nil
      guard hadCachedMetadata else { continue }

      if let currentThumbnailPath {
        clearedThumbnailPaths.insert(currentThumbnailPath)
      }
      try message.setMetadata(title: nil, thumbnailURL: nil)
      clearedStorageIDs.insert(message.storageID)
      didChange = true
    }

    if didChange {
      try modelContext.save()
      for thumbnailPath in clearedThumbnailPaths {
        pruneManagedThumbnailIfUnreferenced(
          thumbnailPath: thumbnailPath,
          excludingStorageIDs: clearedStorageIDs
        )
      }
    }
  }

  private func managedStorageUsage(messages: [SessionMessageEntity]) -> ManagedStorageUsage {
    let previewURLs = Set(
      messages.compactMap { message in
        ManagedLocalFileScope.shared.managedFileURL(fromPath: message.thumbnailURL)
      }
    )
    let cachedMediaURLs = Set(
      messages.compactMap { message in
        ManagedLocalFileScope.shared.managedFileURL(fromPath: message.cachedMediaPath)
      }
    )

    return ManagedStorageUsage(
      previewBytes: previewURLs.reduce(into: Int64(0)) { total, fileURL in
        total += LocalFileMetrics.allocatedSize(at: fileURL)
      },
      cachedMediaBytes: cachedMediaURLs.reduce(into: Int64(0)) { total, fileURL in
        total += LocalFileMetrics.allocatedSize(at: fileURL)
      }
    )
  }

  private func pruneManagedThumbnailIfUnreferenced(
    thumbnailPath: String,
    excludingStorageIDs: Set<String> = []
  ) {
    guard
      let managedThumbnailURL = ManagedLocalFileScope.shared.managedFileURL(fromPath: thumbnailPath)
    else {
      return
    }

    let messages = (try? modelContext.fetch(FetchDescriptor<SessionMessageEntity>())) ?? []
    let hasOtherReference = messages.contains { message in
      guard !excludingStorageIDs.contains(message.storageID) else { return false }
      return ManagedLocalFileScope.shared.normalizedManagedPath(message.thumbnailURL)
        == managedThumbnailURL.path
    }
    guard !hasOtherReference else { return }

    ThumbnailImageCache.shared.removeImage(at: managedThumbnailURL.path)
    try? FileManager.default.removeItem(at: managedThumbnailURL)
  }

  func managedStoredFileURLs(for messages: [SessionMessageEntity]) -> Set<URL> {
    Set(
      messages.flatMap { message in
        [
          ManagedLocalFileScope.shared.managedFileURL(fromPath: message.thumbnailURL),
          ManagedLocalFileScope.shared.managedFileURL(fromPath: message.cachedMediaPath)
        ].compactMap { $0 }
      }
    )
  }

  func removeManagedFiles(at fileURLs: Set<URL>) {
    for fileURL in fileURLs {
      try? FileManager.default.removeItem(at: fileURL)
    }
  }
}
