import Foundation
import SwiftData

// MARK: - SessionMessageStore Queries

extension SessionMessageStore {
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

  func upsertReaction(_ params: UpsertReactionParams) throws {
    let normalizedEmoji = params.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEmoji.isEmpty else { return }
    guard let normalizedSenderPubkey = NostrValueNormalizer.normalizedPubkeyHex(params.senderPubkey)
    else {
      throw NostrServiceError.invalidPubkey
    }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(params.eventID) ?? ""

    let storageID = SessionReactionEntity.storageID(
      ownerPubkey: params.ownerPubkey,
      sessionID: params.sessionID,
      postID: params.postID,
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
          incomingUpdatedAt: params.updatedAt,
          incomingEventID: normalizedEventID
        )
      else {
        return
      }
      existing.isActive = params.isActive
      existing.updatedAt = params.updatedAt
      existing.lastEventID = normalizedEventID
      try modelContext.save()
      return
    }

    let reaction = try SessionReactionEntity(
      ownerPubkey: params.ownerPubkey,
      sessionID: params.sessionID,
      postID: params.postID,
      emoji: normalizedEmoji,
      senderPubkey: normalizedSenderPubkey,
      isActive: params.isActive,
      updatedAt: params.updatedAt,
      eventID: normalizedEventID
    )
    modelContext.insert(reaction)
    try modelContext.save()
  }

  func rootPost(ownerPubkey: String, sessionID: String, rootID: String) throws
    -> SessionMessageEntity? {
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

  func ensureOpenMemberInterval(
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

  func closeOpenMemberInterval(
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
    -> [SessionMemberEntity] {
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
}
