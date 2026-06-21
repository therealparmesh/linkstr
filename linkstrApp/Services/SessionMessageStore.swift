import Foundation
import SwiftData

struct ApplyRootDeletionParams {
  let ownerPubkey: String
  let sessionID: String
  let rootID: String
  let deletedByPubkey: String
  let updatedAt: Date
  let eventID: String
}

struct UpsertReactionParams {
  let ownerPubkey: String
  let sessionID: String
  let postID: String
  let emoji: String
  let senderPubkey: String
  let isActive: Bool
  let updatedAt: Date
  let eventID: String
}

@MainActor
final class SessionMessageStore {
  let modelContext: ModelContext

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
    -> SessionDeletionTombstoneEntity? {
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

  func applyMemberSnapshot(
    ownerPubkey: String,
    sessionID: String,
    memberPubkeys: [String],
    updatedAt: Date,
    eventID: String? = nil
  ) throws {
    let normalizedMembers = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(memberPubkeys)
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
    let existingByHash = Dictionary(
      existingMembers.map { ($0.memberPubkeyHash, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let desiredHashes = Set(normalizedMembers.map { LocalDataCrypto.shared.digestHex($0) })

    var didChange = try activateOrCreateMembers(
      normalizedMembers: normalizedMembers,
      existingByHash: existingByHash,
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      updatedAt: updatedAt
    )
    if try deactivateRemovedMembers(
      existingMembers: existingMembers,
      desiredHashes: desiredHashes,
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      updatedAt: updatedAt
    ) {
      didChange = true
    }
    if updateMembershipState(sessionEntity, updatedAt: updatedAt, eventID: eventID) {
      didChange = true
    }
    if didChange {
      try modelContext.save()
    }
  }

  private func activateOrCreateMembers(
    normalizedMembers: [String],
    existingByHash: [String: SessionMemberEntity],
    ownerPubkey: String,
    sessionID: String,
    updatedAt: Date
  ) throws -> Bool {
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
      if try ensureOpenMemberInterval(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkey: memberPubkey,
        startedAt: updatedAt
      ) {
        didChange = true
      }
    }
    return didChange
  }

  private func deactivateRemovedMembers(
    existingMembers: [SessionMemberEntity],
    desiredHashes: Set<String>,
    sessionID: String,
    ownerPubkey: String,
    updatedAt: Date
  ) throws -> Bool {
    var didChange = false
    for existing in existingMembers {
      guard existing.updatedAt <= updatedAt else { continue }
      if !desiredHashes.contains(existing.memberPubkeyHash), existing.isActive {
        existing.apply(isActive: false, updatedAt: updatedAt)
        _ = try closeOpenMemberInterval(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkeyHash: existing.memberPubkeyHash,
          endedAt: updatedAt
        )
        didChange = true
      }
    }
    return didChange
  }

  private func updateMembershipState(
    _ sessionEntity: SessionEntity,
    updatedAt: Date,
    eventID: String?
  ) -> Bool {
    let membershipEventID = NostrValueNormalizer.normalizedEventID(eventID)
    if sessionEntity.membershipStateUpdatedAt != updatedAt
      || sessionEntity.membershipStateEventID != membershipEventID {
      sessionEntity.membershipStateUpdatedAt = updatedAt
      sessionEntity.membershipStateEventID = membershipEventID
      return true
    }
    return false
  }

}
