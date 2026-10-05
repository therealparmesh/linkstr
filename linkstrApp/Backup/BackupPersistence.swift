import Foundation
import NostrSDK
import SwiftData

struct BackupActivation: Codable, Sendable {
  let nsec: String
  let owner: String
  let settings: LinkstrBackup.Settings
}

extension LinkstrBackup {
  private struct CachedPost {
    let thumbnail: String?
    let title: String?
    let path: String?
    let source: String?
    let type: String

    init(_ row: SessionMessageEntity) {
      thumbnail = row.encryptedThumbnailURL
      title = row.encryptedMetadataTitle
      path = row.cachedMediaPath
      source = row.cachedMediaSourceURL
      type = row.linkTypeRaw
    }
  }

  func replaceAccount(in context: ModelContext) throws -> Set<URL> {
    let owner = owner
    let existingPosts = try context.fetch(FetchDescriptor<SessionMessageEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    }))
    let cachedPosts = Dictionary(uniqueKeysWithValues: existingPosts.map { ($0.eventID, CachedPost($0)) })
    let files = Set(existingPosts.flatMap { row in
      [row.thumbnailURL, row.cachedMediaPath].compactMap {
        ManagedLocalFileScope.shared.managedFileURL(fromPath: $0)
      }
    })
    try deleteRecords(in: context)
    let state = AccountStateEntity(ownerPubkey: owner)
    state.hasRestoredBackup = true
    if let account {
      state.followListUpdatedAt = account.followDate
      state.followListEventID = account.followID
      state.followListTags = account.followTags
      state.nostrProfileName = account.profileName
      state.profileMetadataContent = account.profileContent
      state.profileMetadataUpdatedAt = account.profileDate
      state.profileMetadataEventID = account.profileID
      state.createdAt = account.createdAt
      state.updatedAt = account.updatedAt
    }
    let activation = BackupActivation(nsec: nsec, owner: owner, settings: settings)
    guard let payload = String(data: try JSONEncoder().encode(activation), encoding: .utf8)
    else { throw BackupError.invalidFile }
    state.pendingRestoreActivation = try LocalDataCrypto.shared.encryptString(payload, ownerPubkey: owner)
    context.insert(state)
    try insertSessions(in: context)
    let archives = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.archived) })
    try insertPosts(in: context, archives: archives, cachedPosts: cachedPosts)
    try insertRelationships(in: context)
    for relay in try context.fetch(FetchDescriptor<RelayEntity>()) { context.delete(relay) }
    for relay in settings.relays {
      context.insert(RelayEntity(url: relay.url, isEnabled: relay.enabled, createdAt: relay.createdAt))
    }
    return files
  }

  private func insertPosts(
    in context: ModelContext, archives: [String: Bool], cachedPosts: [String: CachedPost]
  ) throws {
    for post in posts {
      let cached = cachedPosts[post.id]
      let row = try SessionMessageEntity(
        eventID: post.id, ownerPubkey: owner, conversationID: post.sessionID, rootID: post.id,
        kind: .root, senderPubkey: post.sender, receiverPubkey: post.receiver,
        url: post.url, note: post.note, timestamp: post.timestamp,
        isArchived: archives[post.sessionID] ?? post.archived, readAt: post.readAt,
        linkType: URLClassifier.classify(post.url), publishedTransportEventIDs: post.transportIDs)
      if let cached {
        row.encryptedThumbnailURL = cached.thumbnail
        row.encryptedMetadataTitle = cached.title
        row.cachedMediaPath = cached.path
        row.cachedMediaSourceURL = cached.source
        row.linkTypeRaw = cached.type
      }
      context.insert(row)
    }
  }

  private func insertSessions(in context: ModelContext) throws {
    for session in sessions {
      context.insert(try SessionEntity(
        ownerPubkey: owner, sessionID: session.id, name: session.name, createdByPubkey: session.creator,
        createdAt: session.createdAt, updatedAt: session.updatedAt, isArchived: session.archived,
        membershipStateUpdatedAt: session.membershipDate, membershipStateEventID: session.membershipID))
    }
    for member in members {
      context.insert(try SessionMemberEntity(
        ownerPubkey: owner, sessionID: member.sessionID, memberPubkey: member.pubkey,
        isActive: member.active, createdAt: member.createdAt, updatedAt: member.updatedAt))
    }
    for interval in intervals {
      context.insert(try SessionMemberIntervalEntity(
        ownerPubkey: owner, sessionID: interval.sessionID, memberPubkey: interval.pubkey,
        startAt: interval.start, endAt: interval.end))
    }
    for reaction in reactions {
      context.insert(try SessionReactionEntity(
        ownerPubkey: owner, sessionID: reaction.sessionID, postID: reaction.postID,
        emoji: reaction.emoji, senderPubkey: reaction.pubkey, isActive: reaction.active,
        updatedAt: reaction.updatedAt, eventID: reaction.eventID))
    }
    for deletion in deletions {
      if let postID = deletion.postID {
        context.insert(try SessionPostDeletionEntity(
          ownerPubkey: owner, sessionID: deletion.sessionID, rootID: postID,
          deletedByPubkey: deletion.pubkey, updatedAt: deletion.updatedAt, eventID: deletion.eventID))
      } else {
        context.insert(try SessionDeletionTombstoneEntity(
          ownerPubkey: owner, sessionID: deletion.sessionID, deletedByPubkey: deletion.pubkey,
          updatedAt: deletion.updatedAt, eventID: deletion.eventID))
      }
    }
  }

  private func insertRelationships(in context: ModelContext) throws {
    for contact in contacts {
      let row = try ContactEntity(
        ownerPubkey: owner, targetPubkey: contact.pubkey, alias: contact.alias, createdAt: contact.createdAt)
      row.nostrProfileName = contact.profileName
      row.profileMetadataUpdatedAt = contact.profileDate
      row.profileMetadataEventID = contact.profileID
      context.insert(row)
    }
    for follow in follows {
      context.insert(FollowRelationshipEntity(ownerPubkey: owner, incoming: ReceivedFollowList(
        eventID: follow.eventID, authorPubkey: follow.pubkey,
        followedPubkeys: follow.follows ? [owner] : [], createdAt: follow.updatedAt)))
    }
    for preference in preferences {
      let event = try JSONDecoder().decode(NostrEvent.self, from: preference.event)
      guard let identifier = event.firstValueForRawTagName("d") else { throw BackupError.invalidFile }
      context.insert(try PrivatePreferenceEntity(
        event: event, identifier: identifier, needsPublish: preference.pending))
    }
  }

  private func deleteRecords(in context: ModelContext) throws {
    let owner = owner
    func remove<T: PersistentModel>(_ predicate: Predicate<T>) throws {
      for row in try context.fetch(FetchDescriptor<T>(predicate: predicate)) { context.delete(row) }
    }
    try remove(#Predicate<AccountStateEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<ContactEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<FollowRelationshipEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<PrivatePreferenceEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<SessionEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<SessionMessageEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<SessionMemberEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<SessionMemberIntervalEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<SessionReactionEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<SessionDeletionTombstoneEntity> { $0.ownerPubkey == owner })
    try remove(#Predicate<SessionPostDeletionEntity> { $0.ownerPubkey == owner })
  }
}

actor BackupWorker {
  func export(_ snapshot: BackupSnapshot) throws -> Data {
    let backup = try snapshot.decrypted()
    try backup.validate()
    let data = try JSONEncoder().encode(backup)
    guard data.count <= LinkstrBackup.maximumFileBytes else { throw BackupError.tooLarge }
    return data
  }

  func restore(_ backup: LinkstrBackup, in container: ModelContainer) throws -> Set<URL> {
    try backup.validate()
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let snapshot = try BackupSnapshot(
      context: context, nsec: backup.nsec, owner: backup.owner, settings: backup.settings)
    let local = try snapshot.decrypted()
    try local.validate()
    let merged = try local.merging(backup)
    do {
      let files = try merged.replaceAccount(in: context)
      try context.save()
      return files
    } catch {
      context.rollback()
      throw error
    }
  }

  func pendingActivation(in container: ModelContainer) throws -> BackupActivation? {
    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<AccountStateEntity>(predicate: #Predicate {
      $0.pendingRestoreActivation != nil
    }))
    guard let record = records.first else { return nil }
    guard records.count == 1,
      let plaintext = try LocalDataCrypto.shared.decryptStringStrict(
        record.pendingRestoreActivation, ownerPubkey: record.ownerPubkey)
    else { throw BackupError.invalidFile }
    let activation = try JSONDecoder().decode(BackupActivation.self, from: Data(plaintext.utf8))
    guard Keypair(nsec: activation.nsec)?.publicKey.hex == record.ownerPubkey,
      activation.owner == record.ownerPubkey else { throw BackupError.invalidFile }
    return activation
  }

  func finishActivation(owner: String, in container: ModelContainer) throws {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let records = try context.fetch(FetchDescriptor<AccountStateEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    }))
    guard let record = records.first else { throw BackupError.invalidFile }
    record.pendingRestoreActivation = nil
    try context.save()
  }
}
