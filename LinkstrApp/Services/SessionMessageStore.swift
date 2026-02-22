import Foundation
import NostrSDK
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

  func message(eventID: String, ownerPubkey: String) throws -> SessionMessageEntity? {
    let storageID = SessionMessageEntity.storageID(ownerPubkey: ownerPubkey, eventID: eventID)
    return try message(storageID: storageID)
  }

  func message(storageID: String) throws -> SessionMessageEntity? {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
  }

  func rootMessages(ownerPubkey: String) throws -> [SessionMessageEntity] {
    let rootKindRaw = SessionMessageKind.root.rawValue
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey && $0.kindRaw == rootKindRaw
      }
    )
    return try modelContext.fetch(descriptor)
  }

  func session(sessionID: String, ownerPubkey: String) throws -> SessionEntity? {
    let storageID = SessionEntity.storageID(ownerPubkey: ownerPubkey, sessionID: sessionID)
    let descriptor = FetchDescriptor<SessionEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
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
    let effectiveName = normalizedName.isEmpty ? "Untitled Session" : normalizedName

    if let existing = try session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
      var didChange = false
      if existing.name != effectiveName {
        let renameUpdatedAt = max(existing.updatedAt, updatedAt)
        try existing.updateName(effectiveName, updatedAt: renameUpdatedAt)
        didChange = true
      }
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

  func applyMemberSnapshot(
    ownerPubkey: String,
    sessionID: String,
    memberPubkeys: [String],
    updatedAt: Date
  ) throws {
    let normalizedMembers = normalizedPubkeys(memberPubkeys)
    guard !normalizedMembers.isEmpty else { return }

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
        didChange = true
      }
    }

    for existing in existingMembers {
      guard existing.updatedAt <= updatedAt else { continue }
      if !desiredHashes.contains(existing.memberPubkeyHash), existing.isActive {
        existing.apply(isActive: false, updatedAt: updatedAt)
        didChange = true
      }
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

  func upsertReaction(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    emoji: String,
    senderPubkey: String,
    isActive: Bool,
    updatedAt: Date
  ) throws {
    let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEmoji.isEmpty else { return }
    let normalizedSenderPubkey = try normalizedPubkey(senderPubkey)

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
      guard existing.updatedAt <= updatedAt else { return }
      existing.isActive = isActive
      existing.updatedAt = updatedAt
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
      updatedAt: updatedAt
    )
    modelContext.insert(reaction)
    try modelContext.save()
  }

  func markRootPostRead(postID: String, ownerPubkey: String, myPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.rootID == postID && $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.kind == .root {
      guard !message.senderMatches(myPubkey), message.readAt == nil else { continue }
      message.readAt = .now
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func purgeLegacyNonRootMessages(ownerPubkey: String) throws {
    let rootKindRaw = SessionMessageKind.root.rawValue
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.kindRaw != rootKindRaw }
    )
    let messages = try modelContext.fetch(descriptor)
    guard !messages.isEmpty else { return }
    messages.forEach(modelContext.delete)
    try modelContext.save()
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
    let reactions = try modelContext.fetch(
      FetchDescriptor<SessionReactionEntity>(
        predicate: #Predicate { $0.ownerPubkey == ownerPubkey })
    )

    messages.forEach(modelContext.delete)
    sessions.forEach(modelContext.delete)
    members.forEach(modelContext.delete)
    reactions.forEach(modelContext.delete)
    try modelContext.save()
  }

  func clearCachedVideos(ownerPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.cachedMediaPath != nil {
      if let path = message.cachedMediaPath {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
      }
      message.cachedMediaPath = nil
      message.cachedMediaSourceURL = nil
      didChange = true
    }
    if didChange {
      try modelContext.save()
    }
  }

  private func normalizedPubkeys(_ candidates: [String]) -> [String] {
    var normalized: [String] = []
    var seen = Set<String>()

    for candidate in candidates {
      guard let key = PublicKey(hex: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
      else {
        continue
      }
      guard !seen.contains(key.hex) else { continue }
      seen.insert(key.hex)
      normalized.append(key.hex)
    }

    return normalized
  }

  private func normalizedPubkey(_ candidate: String) throws -> String {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key = PublicKey(hex: trimmed) else {
      throw NostrServiceError.invalidPubkey
    }
    return key.hex
  }
}
