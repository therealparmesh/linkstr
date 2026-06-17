import Foundation
import SwiftData

@MainActor
final class SessionMessageStore {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func insert(_ message: SessionMessageEntity) throws {
    modelContext.insert(message)
    try modelContext.save()
  }

  func message(storageID: String) throws -> SessionMessageEntity? {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
  }

  func session(sessionID: String, ownerPubkey: String) throws -> SessionEntity? {
    let storageID = SessionEntity.storageID(ownerPubkey: ownerPubkey, sessionID: sessionID)
    let descriptor = FetchDescriptor<SessionEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
  }

  func sessionDeletionTombstone(sessionID: String, ownerPubkey: String) throws
    -> SessionDeletionTombstoneEntity?
  {
    let storageID = SessionDeletionTombstoneEntity.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID
    )
    let descriptor = FetchDescriptor<SessionDeletionTombstoneEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
  }

  func archivedConversationIDs(ownerPubkey: String) throws -> [String] {
    let descriptor = FetchDescriptor<SessionEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.isArchived == true }
    )
    return try modelContext.fetch(descriptor).map(\.sessionID)
  }

  func hasPersistedConversationState(ownerPubkey: String) throws -> Bool {
    let sessionDescriptor = FetchDescriptor<SessionEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    if !(try modelContext.fetch(sessionDescriptor)).isEmpty {
      return true
    }

    let rootKindRaw = SessionMessageKind.root.rawValue
    let messageDescriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey && $0.kindRaw == rootKindRaw
      }
    )
    if !(try modelContext.fetch(messageDescriptor)).isEmpty {
      return true
    }

    let tombstoneDescriptor = FetchDescriptor<SessionDeletionTombstoneEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    return !(try modelContext.fetch(tombstoneDescriptor)).isEmpty
  }

  @discardableResult
  func upsertSession(
    ownerPubkey: String,
    sessionID: String,
    name: String,
    createdByPubkey: String,
    updatedAt: Date,
    isArchived: Bool? = nil
  ) throws -> SessionEntity {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveName = normalizedName.isEmpty ? "untitled session" : normalizedName

    if let existing = try session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
      var didChange = false
      if existing.updatedAt < updatedAt {
        existing.updatedAt = updatedAt
        didChange = true
      }
      if let isArchived, existing.isArchived != isArchived {
        existing.isArchived = isArchived
        didChange = true
      }
      if didChange {
        try modelContext.save()
      }
      return existing
    }

    let entity = try SessionEntity(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      name: effectiveName,
      createdByPubkey: createdByPubkey,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      isArchived: isArchived ?? false
    )
    modelContext.insert(entity)
    try modelContext.save()
    return entity
  }

  func setSessionArchived(sessionID: String, ownerPubkey: String, archived: Bool) throws {
    var didChange = false

    if let session = try session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
      if session.isArchived != archived {
        session.isArchived = archived
        session.updatedAt = .now
        didChange = true
      }
    }

    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.conversationID == sessionID && $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)
    for message in messages {
      guard message.isArchived != archived else { continue }
      message.isArchived = archived
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func members(sessionID: String, ownerPubkey: String, activeOnly: Bool = true) throws
    -> [SessionMemberEntity]
  {
    if activeOnly {
      let descriptor = FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID && $0.isActive == true
        },
        sortBy: [SortDescriptor(\.createdAt)]
      )
      return try modelContext.fetch(descriptor)
    }

    let descriptor = FetchDescriptor<SessionMemberEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    return try modelContext.fetch(descriptor)
  }

  func isMemberActive(
    sessionID: String,
    ownerPubkey: String,
    memberPubkey: String,
    at timestamp: Date = .now
  ) throws -> Bool {
    guard let normalizedMemberPubkey = NostrValueNormalizer.normalizedPubkeyHex(memberPubkey) else {
      throw NostrServiceError.invalidPubkey
    }
    let memberHash = LocalDataCrypto.shared.digestHex(normalizedMemberPubkey)
    let intervals = try memberIntervals(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      memberPubkeyHash: memberHash
    )
    if let matchingInterval = intervals.last(where: { $0.contains(timestamp) }) {
      let intervalPubkey = matchingInterval.memberPubkey
      return intervalPubkey == normalizedMemberPubkey
    }

    // Backward-compat fallback for legacy rows created before interval tracking.
    let existingMembers = try members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: false
    )
    guard let legacyMember = existingMembers.first(where: { $0.memberPubkeyHash == memberHash })
    else {
      return false
    }
    guard legacyMember.updatedAt <= timestamp else { return false }
    return legacyMember.isActive
  }

  func shouldApplyMemberSnapshot(
    ownerPubkey: String,
    sessionID: String,
    updatedAt: Date,
    eventID: String? = nil
  ) throws -> Bool {
    guard let sessionEntity = try session(sessionID: sessionID, ownerPubkey: ownerPubkey) else {
      return false
    }
    let existingMembers = try members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: false
    )
    let fallbackSnapshotUpdatedAt = existingMembers.map(\.updatedAt).max()
    return NostrValueNormalizer.shouldApplyStateUpdate(
      currentUpdatedAt: sessionEntity.membershipStateUpdatedAt ?? fallbackSnapshotUpdatedAt,
      currentEventID: sessionEntity.membershipStateEventID,
      incomingUpdatedAt: updatedAt,
      incomingEventID: eventID
    )
  }

  func applyMemberSnapshot(
    ownerPubkey: String,
    sessionID: String,
    memberPubkeys: [String],
    updatedAt: Date,
    eventID: String? = nil
  ) throws {
    let normalizedMembers = normalizedPubkeys(memberPubkeys)
    guard !normalizedMembers.isEmpty else { return }
    guard let sessionEntity = try session(sessionID: sessionID, ownerPubkey: ownerPubkey) else {
      return
    }
    guard
      try shouldApplyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        updatedAt: updatedAt,
        eventID: eventID
      )
    else {
      return
    }
    let existingMembers = try members(
      sessionID: sessionID, ownerPubkey: ownerPubkey, activeOnly: false)
    var existingByHash: [String: SessionMemberEntity] = [:]
    for member in existingMembers {
      existingByHash[member.memberPubkeyHash] = member
    }

    let desiredHashes = Set(normalizedMembers.map { LocalDataCrypto.shared.digestHex($0) })
    var didChange = false

    for memberPubkey in normalizedMembers {
      let hash = LocalDataCrypto.shared.digestHex(memberPubkey)
      if let existing = existingByHash[hash] {
        guard existing.updatedAt <= updatedAt else { continue }
        if existing.isActive == false || existing.updatedAt != updatedAt {
          existing.apply(isActive: true, updatedAt: updatedAt)
          didChange = true
        }
        if try ensureOpenMemberInterval(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          memberPubkey: memberPubkey,
          startedAt: updatedAt
        ) {
          didChange = true
        }
      } else {
        let created = try SessionMemberEntity(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          memberPubkey: memberPubkey,
          isActive: true,
          createdAt: updatedAt,
          updatedAt: updatedAt
        )
        modelContext.insert(created)
        _ = try ensureOpenMemberInterval(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          memberPubkey: memberPubkey,
          startedAt: updatedAt
        )
        didChange = true
      }
    }

    for existing in existingMembers {
      guard existing.updatedAt <= updatedAt else { continue }
      if !desiredHashes.contains(existing.memberPubkeyHash), existing.isActive {
        existing.apply(isActive: false, updatedAt: updatedAt)
        if try closeOpenMemberInterval(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkeyHash: existing.memberPubkeyHash,
          endedAt: updatedAt
        ) {
          didChange = true
        }
        didChange = true
      }
    }

    let membershipEventID = NostrValueNormalizer.normalizedEventID(eventID)
    if sessionEntity.membershipStateUpdatedAt != updatedAt
      || sessionEntity.membershipStateEventID != membershipEventID
    {
      sessionEntity.membershipStateUpdatedAt = updatedAt
      sessionEntity.membershipStateEventID = membershipEventID
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func reactions(ownerPubkey: String, sessionID: String? = nil) throws -> [SessionReactionEntity] {
    if let sessionID {
      let descriptor = FetchDescriptor<SessionReactionEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
      )
      return try modelContext.fetch(descriptor)
    }

    let descriptor = FetchDescriptor<SessionReactionEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    return try modelContext.fetch(descriptor)
  }

  func knownSessionTransportEventIDs(ownerPubkey: String, sessionID: String) throws -> [String] {
    let rootKindRaw = SessionMessageKind.root.rawValue
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey
          && $0.conversationID == sessionID
          && $0.kindRaw == rootKindRaw
      }
    )
    let messages = try modelContext.fetch(descriptor)
    return NostrValueNormalizer.dedupedNormalizedEventIDs(
      messages.flatMap(\.publishedTransportEventIDs)
    )
  }

  func hasRootPosts(ownerPubkey: String, sessionID: String) throws -> Bool {
    let rootKindRaw = SessionMessageKind.root.rawValue
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey
          && $0.conversationID == sessionID
          && $0.kindRaw == rootKindRaw
      }
    )
    return !(try modelContext.fetch(descriptor)).isEmpty
  }

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

  func hasRootDeletion(
    ownerPubkey: String,
    sessionID: String,
    rootID: String,
    deletedByPubkey: String
  ) throws -> Bool {
    try rootDeletion(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      rootID: rootID,
      deletedByPubkey: deletedByPubkey
    ) != nil
  }

  func rootDeletion(
    ownerPubkey: String,
    sessionID: String,
    rootID: String,
    deletedByPubkey: String
  ) throws -> SessionPostDeletionEntity? {
    guard let normalizedDeletedByPubkey = NostrValueNormalizer.normalizedPubkeyHex(deletedByPubkey)
    else {
      throw NostrServiceError.invalidPubkey
    }
    let storageID = SessionPostDeletionEntity.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      rootID: rootID,
      deletedByPubkey: normalizedDeletedByPubkey
    )
    let descriptor = FetchDescriptor<SessionPostDeletionEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
  }

  @discardableResult
  func applyRootDeletion(
    ownerPubkey: String,
    sessionID: String,
    rootID: String,
    deletedByPubkey: String,
    updatedAt: Date,
    eventID: String
  ) throws -> Bool {
    guard let normalizedDeletedByPubkey = NostrValueNormalizer.normalizedPubkeyHex(deletedByPubkey)
    else {
      throw NostrServiceError.invalidPubkey
    }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID) ?? ""
    let deletionStorageID = SessionPostDeletionEntity.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      rootID: rootID,
      deletedByPubkey: normalizedDeletedByPubkey
    )
    let deletionDescriptor = FetchDescriptor<SessionPostDeletionEntity>(
      predicate: #Predicate { $0.storageID == deletionStorageID }
    )

    var didChange = false
    if let existingDeletion = try modelContext.fetch(deletionDescriptor).first {
      if NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: existingDeletion.updatedAt,
        currentEventID: existingDeletion.lastEventID,
        incomingUpdatedAt: updatedAt,
        incomingEventID: normalizedEventID
      ) {
        existingDeletion.updatedAt = updatedAt
        existingDeletion.lastEventID = normalizedEventID
        didChange = true
      }
    } else {
      let deletion = try SessionPostDeletionEntity(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: rootID,
        deletedByPubkey: normalizedDeletedByPubkey,
        updatedAt: updatedAt,
        eventID: normalizedEventID
      )
      modelContext.insert(deletion)
      didChange = true
    }

    let storedRoot = try rootPost(ownerPubkey: ownerPubkey, sessionID: sessionID, rootID: rootID)
    let deletedByHash = LocalDataCrypto.shared.digestHex(normalizedDeletedByPubkey)
    let matchingRootMessages =
      storedRoot.map { $0.senderMatchesHash(deletedByHash) ? [$0] : [] } ?? []
    let storedFileURLs = managedStoredFileURLs(for: matchingRootMessages)
    if !matchingRootMessages.isEmpty {
      matchingRootMessages.forEach(modelContext.delete)
      didChange = true
    }

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

    if didChange {
      try modelContext.save()
    }

    removeManagedFiles(at: storedFileURLs)

    return didChange
  }

  func upsertReaction(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    emoji: String,
    senderPubkey: String,
    isActive: Bool,
    updatedAt: Date,
    eventID: String
  ) throws {
    let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEmoji.isEmpty else { return }
    guard let normalizedSenderPubkey = NostrValueNormalizer.normalizedPubkeyHex(senderPubkey) else {
      throw NostrServiceError.invalidPubkey
    }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID) ?? ""

    let storageID = SessionReactionEntity.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      postID: postID,
      emoji: normalizedEmoji,
      senderPubkey: normalizedSenderPubkey
    )
    let descriptor = FetchDescriptor<SessionReactionEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )

    if let existing = try modelContext.fetch(descriptor).first {
      guard
        NostrValueNormalizer.shouldApplyStateUpdate(
          currentUpdatedAt: existing.updatedAt,
          currentEventID: existing.lastEventID,
          incomingUpdatedAt: updatedAt,
          incomingEventID: normalizedEventID
        )
      else {
        return
      }
      existing.isActive = isActive
      existing.updatedAt = updatedAt
      existing.lastEventID = normalizedEventID
      try modelContext.save()
      return
    }

    let reaction = try SessionReactionEntity(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      postID: postID,
      emoji: normalizedEmoji,
      senderPubkey: normalizedSenderPubkey,
      isActive: isActive,
      updatedAt: updatedAt,
      eventID: normalizedEventID
    )
    modelContext.insert(reaction)
    try modelContext.save()
  }

  func rootPost(ownerPubkey: String, sessionID: String, rootID: String) throws
    -> SessionMessageEntity?
  {
    let storageID = SessionMessageEntity.storageID(
      ownerPubkey: ownerPubkey,
      eventID: rootID
    )
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    guard let message = try modelContext.fetch(descriptor).first else { return nil }
    guard message.conversationID == sessionID, message.kind == .root else { return nil }
    return message
  }

  func markRootPostRead(postID: String, ownerPubkey: String, myPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.rootID == postID && $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    let myPubkeyHash = LocalDataCrypto.shared.digestHex(myPubkey)
    for message in messages where message.kind == .root {
      guard !message.senderMatchesHash(myPubkeyHash), message.readAt == nil else { continue }
      message.readAt = .now
      didChange = true
    }

    if didChange {
      try modelContext.save()
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

  func clearAllSessionData(ownerPubkey: String) throws {
    let messages = try modelContext.fetch(
      FetchDescriptor<SessionMessageEntity>(predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )
    let sessions = try modelContext.fetch(
      FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )
    let members = try modelContext.fetch(
      FetchDescriptor<SessionMemberEntity>(predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )
    let intervals = try modelContext.fetch(
      FetchDescriptor<SessionMemberIntervalEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )
    let reactions = try modelContext.fetch(
      FetchDescriptor<SessionReactionEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )
    let deletions = try modelContext.fetch(
      FetchDescriptor<SessionPostDeletionEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )
    let tombstones = try modelContext.fetch(
      FetchDescriptor<SessionDeletionTombstoneEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )

    let storedFileURLs = managedStoredFileURLs(for: messages)

    messages.forEach(modelContext.delete)
    sessions.forEach(modelContext.delete)
    members.forEach(modelContext.delete)
    intervals.forEach(modelContext.delete)
    reactions.forEach(modelContext.delete)
    deletions.forEach(modelContext.delete)
    tombstones.forEach(modelContext.delete)
    try modelContext.save()

    removeManagedFiles(at: storedFileURLs)
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
        fromPath: message.cachedMediaPath)
      {
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
      let currentThumbnailPath = ManagedLocalFileScope.shared.normalizedManagedPath(message.thumbnailURL)
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

  private func normalizedPubkeys(_ candidates: [String]) -> [String] {
    NostrValueNormalizer.dedupedNormalizedPubkeyHexes(candidates)
  }

  func memberIntervals(
    sessionID: String,
    ownerPubkey: String,
    memberPubkeyHash: String
  ) throws -> [SessionMemberIntervalEntity] {
    let descriptor = FetchDescriptor<SessionMemberIntervalEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey
          && $0.sessionID == sessionID
          && $0.memberPubkeyHash == memberPubkeyHash
      },
      sortBy: [SortDescriptor(\.startAt)]
    )
    return try modelContext.fetch(descriptor)
  }

  private func ensureOpenMemberInterval(
    ownerPubkey: String,
    sessionID: String,
    memberPubkey: String,
    startedAt: Date
  ) throws -> Bool {
    let memberHash = LocalDataCrypto.shared.digestHex(memberPubkey)
    let intervals = try memberIntervals(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      memberPubkeyHash: memberHash
    )
    if intervals.contains(where: { $0.endAt == nil }) {
      return false
    }

    let interval = try SessionMemberIntervalEntity(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      memberPubkey: memberPubkey,
      startAt: startedAt
    )
    modelContext.insert(interval)
    return true
  }

  private func closeOpenMemberInterval(
    sessionID: String,
    ownerPubkey: String,
    memberPubkeyHash: String,
    endedAt: Date
  ) throws -> Bool {
    let intervals = try memberIntervals(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      memberPubkeyHash: memberPubkeyHash
    )
    guard let openInterval = intervals.last(where: { $0.endAt == nil }) else {
      return false
    }
    openInterval.endAt = max(openInterval.startAt, endedAt)
    return true
  }

  @discardableResult
  private func purgeSessionDataRecords(
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

  private func managedStoredFileURLs(for messages: [SessionMessageEntity]) -> Set<URL> {
    Set(
      messages.flatMap { message in
        [
          ManagedLocalFileScope.shared.managedFileURL(fromPath: message.thumbnailURL),
          ManagedLocalFileScope.shared.managedFileURL(fromPath: message.cachedMediaPath),
        ].compactMap { $0 }
      }
    )
  }

  private func removeManagedFiles(at fileURLs: Set<URL>) {
    for fileURL in fileURLs {
      try? FileManager.default.removeItem(at: fileURL)
    }
  }
}
