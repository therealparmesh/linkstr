import Foundation
import SwiftData

/// Copy encrypted fields on the context's actor; decrypt the fixed snapshot on the worker.
struct BackupSnapshot: Sendable {
  private var archive: LinkstrBackup

  init(context: ModelContext, nsec: String, owner: String, settings: LinkstrBackup.Settings) throws {
    var backup = LinkstrBackup(nsec: nsec, owner: owner, settings: settings)
    if let row = try context.fetch(FetchDescriptor<AccountStateEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).first {
      backup.account = .init(
        followDate: row.followListUpdatedAt, followID: row.followListEventID, followTags: row.followListTags,
        profileName: row.nostrProfileName, profileContent: row.profileMetadataContent,
        profileDate: row.profileMetadataUpdatedAt, profileID: row.profileMetadataEventID,
        createdAt: row.createdAt, updatedAt: row.updatedAt)
    }
    try Self.captureContent(in: context, owner: owner, into: &backup)
    try Self.captureRelationships(in: context, owner: owner, into: &backup)
    archive = backup
  }

  private static func captureContent(
    in context: ModelContext, owner: String, into backup: inout LinkstrBackup
  ) throws {
    backup.sessions = try context.fetch(FetchDescriptor<SessionEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(id: $0.sessionID, name: $0.encryptedName, creator: $0.encryptedCreatedByPubkey,
            createdAt: $0.createdAt, updatedAt: $0.updatedAt, archived: $0.isArchived,
            membershipDate: $0.membershipStateUpdatedAt, membershipID: $0.membershipStateEventID)
    }
    backup.posts = try context.fetch(FetchDescriptor<SessionMessageEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(id: $0.eventID, sessionID: $0.conversationID, sender: $0.encryptedSenderPubkey,
            receiver: $0.encryptedReceiverPubkey, url: $0.encryptedURL ?? "", note: $0.encryptedNote,
            timestamp: $0.timestamp, archived: $0.isArchived, readAt: $0.readAt,
            transportIDs: $0.publishedTransportEventIDs)
    }
    backup.members = try context.fetch(FetchDescriptor<SessionMemberEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(sessionID: $0.sessionID, pubkey: $0.encryptedMemberPubkey, active: $0.isActive,
            createdAt: $0.createdAt, updatedAt: $0.updatedAt)
    }
    backup.intervals = try context.fetch(FetchDescriptor<SessionMemberIntervalEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(sessionID: $0.sessionID, pubkey: $0.encryptedMemberPubkey, start: $0.startAt, end: $0.endAt)
    }
    backup.reactions = try context.fetch(FetchDescriptor<SessionReactionEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(sessionID: $0.sessionID, postID: $0.postID, pubkey: $0.encryptedSenderPubkey,
            emoji: $0.emoji, active: $0.isActive, updatedAt: $0.updatedAt, eventID: $0.lastEventID)
    }
    backup.deletions = try context.fetch(FetchDescriptor<SessionDeletionTombstoneEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(sessionID: $0.sessionID, postID: nil, pubkey: $0.encryptedDeletedByPubkey,
            updatedAt: $0.updatedAt, eventID: $0.lastEventID)
    }
    backup.deletions += try context.fetch(FetchDescriptor<SessionPostDeletionEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(sessionID: $0.sessionID, postID: $0.rootID, pubkey: $0.encryptedDeletedByPubkey,
            updatedAt: $0.updatedAt, eventID: $0.lastEventID)
    }
  }

  private static func captureRelationships(
    in context: ModelContext, owner: String, into backup: inout LinkstrBackup
  ) throws {
    backup.contacts = try context.fetch(FetchDescriptor<ContactEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(pubkey: $0.targetPubkey, alias: $0.encryptedAlias, createdAt: $0.createdAt,
            profileName: $0.nostrProfileName, profileDate: $0.profileMetadataUpdatedAt,
            profileID: $0.profileMetadataEventID)
    }
    backup.follows = try context.fetch(FetchDescriptor<FollowRelationshipEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map {
      .init(pubkey: $0.followerPubkey, follows: $0.followsOwner, updatedAt: $0.updatedAt, eventID: $0.eventID)
    }
    backup.preferences = try context.fetch(FetchDescriptor<PrivatePreferenceEntity>(predicate: #Predicate {
      $0.ownerPubkey == owner
    })).map { .init(event: $0.eventData, pending: $0.needsPublish) }
  }

  func decrypted() throws -> LinkstrBackup {
    var result = archive
    func decrypt(_ value: String?) throws -> String? {
      try LocalDataCrypto.shared.decryptStringStrict(value, ownerPubkey: archive.owner)
    }
    func required(_ value: String) throws -> String {
      guard let plaintext = try decrypt(value) else { throw LocalDataCryptoError.decryptionFailed }
      return plaintext
    }
    for index in result.sessions.indices {
      result.sessions[index].name = try required(result.sessions[index].name)
      result.sessions[index].creator = try required(result.sessions[index].creator)
    }
    for index in result.posts.indices {
      result.posts[index].sender = try required(result.posts[index].sender)
      result.posts[index].receiver = try required(result.posts[index].receiver)
      result.posts[index].url = try required(result.posts[index].url)
      result.posts[index].note = try decrypt(result.posts[index].note)
    }
    for index in result.members.indices {
      result.members[index].pubkey = try required(result.members[index].pubkey)
    }
    for index in result.intervals.indices {
      result.intervals[index].pubkey = try required(result.intervals[index].pubkey)
    }
    for index in result.reactions.indices {
      result.reactions[index].pubkey = try required(result.reactions[index].pubkey)
    }
    for index in result.deletions.indices {
      result.deletions[index].pubkey = try required(result.deletions[index].pubkey)
    }
    for index in result.contacts.indices {
      result.contacts[index].alias = try decrypt(result.contacts[index].alias)
    }
    return result
  }
}
