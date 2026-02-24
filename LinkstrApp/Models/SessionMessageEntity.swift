import Foundation
import SwiftData

enum SessionMessageKind: String, Codable {
  case root
}

@Model
final class SessionMessageEntity {
  @Attribute(.unique) var storageID: String
  var eventID: String
  var ownerPubkey: String
  var conversationID: String
  var rootID: String
  var kindRaw: String
  var senderPubkeyHash: String
  var receiverPubkeyHash: String
  var encryptedSenderPubkey: String
  var encryptedReceiverPubkey: String
  var encryptedURL: String?
  var encryptedNote: String?
  var timestamp: Date
  var isArchived: Bool
  var readAt: Date?
  var linkTypeRaw: String
  var encryptedThumbnailURL: String?
  var encryptedMetadataTitle: String?
  var cachedMediaPath: String?
  var cachedMediaSourceURL: String?

  var senderPubkey: String {
    LocalDataCrypto.shared.decryptString(encryptedSenderPubkey, ownerPubkey: ownerPubkey) ?? ""
  }

  var receiverPubkey: String {
    LocalDataCrypto.shared.decryptString(encryptedReceiverPubkey, ownerPubkey: ownerPubkey) ?? ""
  }

  var url: String? {
    LocalDataCrypto.shared.decryptString(encryptedURL, ownerPubkey: ownerPubkey)
  }

  var note: String? {
    LocalDataCrypto.shared.decryptString(encryptedNote, ownerPubkey: ownerPubkey)
  }

  var thumbnailURL: String? {
    LocalDataCrypto.shared.decryptString(encryptedThumbnailURL, ownerPubkey: ownerPubkey)
  }

  var metadataTitle: String? {
    LocalDataCrypto.shared.decryptString(encryptedMetadataTitle, ownerPubkey: ownerPubkey)
  }

  var kind: SessionMessageKind {
    get { SessionMessageKind(rawValue: kindRaw) ?? .root }
    set { kindRaw = newValue.rawValue }
  }

  var linkType: LinkType {
    get { LinkType(rawValue: linkTypeRaw) ?? .generic }
    set { linkTypeRaw = newValue.rawValue }
  }

  init(
    eventID: String,
    ownerPubkey: String,
    conversationID: String,
    rootID: String,
    kind: SessionMessageKind,
    senderPubkey: String,
    receiverPubkey: String,
    url: String?,
    note: String?,
    timestamp: Date,
    isArchived: Bool = false,
    readAt: Date? = nil,
    linkType: LinkType,
    thumbnailURL: String? = nil,
    metadataTitle: String? = nil,
    cachedMediaPath: String? = nil,
    cachedMediaSourceURL: String? = nil
  ) throws {
    let crypto = LocalDataCrypto.shared
    self.storageID = Self.storageID(ownerPubkey: ownerPubkey, eventID: eventID)
    self.eventID = eventID
    self.ownerPubkey = ownerPubkey
    self.conversationID = conversationID
    self.rootID = rootID
    self.kindRaw = kind.rawValue
    self.senderPubkeyHash = crypto.digestHex(senderPubkey)
    self.receiverPubkeyHash = crypto.digestHex(receiverPubkey)
    self.encryptedSenderPubkey =
      try crypto.encryptString(senderPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.encryptedReceiverPubkey =
      try crypto.encryptString(receiverPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.encryptedURL = try crypto.encryptString(url, ownerPubkey: ownerPubkey)
    self.encryptedNote = try crypto.encryptString(note, ownerPubkey: ownerPubkey)
    self.timestamp = timestamp
    self.isArchived = isArchived
    self.readAt = readAt
    self.linkTypeRaw = linkType.rawValue
    self.encryptedThumbnailURL =
      try crypto.encryptString(thumbnailURL, ownerPubkey: ownerPubkey)
    self.encryptedMetadataTitle =
      try crypto.encryptString(metadataTitle, ownerPubkey: ownerPubkey)
    self.cachedMediaPath = cachedMediaPath
    self.cachedMediaSourceURL = cachedMediaSourceURL
  }

  static func storageID(ownerPubkey: String, eventID: String) -> String {
    "\(ownerPubkey):\(eventID)"
  }

  func setMetadata(title: String?, thumbnailURL: String?) throws {
    let previousEncryptedTitle = encryptedMetadataTitle
    let previousEncryptedThumbnailURL = encryptedThumbnailURL
    do {
      encryptedMetadataTitle = try LocalDataCrypto.shared.encryptString(
        title, ownerPubkey: ownerPubkey)
      encryptedThumbnailURL = try LocalDataCrypto.shared.encryptString(
        thumbnailURL,
        ownerPubkey: ownerPubkey
      )
    } catch {
      encryptedMetadataTitle = previousEncryptedTitle
      encryptedThumbnailURL = previousEncryptedThumbnailURL
      throw error
    }
  }

  func senderMatches(_ pubkeyHex: String) -> Bool {
    senderPubkeyHash == LocalDataCrypto.shared.digestHex(pubkeyHex)
  }
}

@Model
final class SessionEntity {
  @Attribute(.unique) var storageID: String
  var ownerPubkey: String
  var sessionID: String
  var encryptedName: String
  var createdByPubkeyHash: String
  var encryptedCreatedByPubkey: String
  var createdAt: Date
  var updatedAt: Date
  var isArchived: Bool

  var name: String {
    LocalDataCrypto.shared.decryptString(encryptedName, ownerPubkey: ownerPubkey) ?? ""
  }

  var createdByPubkey: String {
    LocalDataCrypto.shared.decryptString(encryptedCreatedByPubkey, ownerPubkey: ownerPubkey) ?? ""
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    name: String,
    createdByPubkey: String,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    isArchived: Bool = false
  ) throws {
    self.storageID = Self.storageID(ownerPubkey: ownerPubkey, sessionID: sessionID)
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.encryptedName =
      try LocalDataCrypto.shared.encryptString(name, ownerPubkey: ownerPubkey) ?? ""
    self.createdByPubkeyHash = LocalDataCrypto.shared.digestHex(createdByPubkey)
    self.encryptedCreatedByPubkey =
      try LocalDataCrypto.shared.encryptString(createdByPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.isArchived = isArchived
  }

  static func storageID(ownerPubkey: String, sessionID: String) -> String {
    "\(ownerPubkey):\(sessionID)"
  }

  func updateName(_ name: String, updatedAt: Date) throws {
    let previousEncryptedName = encryptedName
    do {
      encryptedName = try LocalDataCrypto.shared.encryptString(name, ownerPubkey: ownerPubkey) ?? ""
      self.updatedAt = updatedAt
    } catch {
      encryptedName = previousEncryptedName
      throw error
    }
  }
}

@Model
final class SessionMemberEntity {
  @Attribute(.unique) var storageID: String
  var ownerPubkey: String
  var sessionID: String
  var memberPubkeyHash: String
  var encryptedMemberPubkey: String
  var isActive: Bool
  var updatedAt: Date
  var createdAt: Date

  var memberPubkey: String {
    LocalDataCrypto.shared.decryptString(encryptedMemberPubkey, ownerPubkey: ownerPubkey) ?? ""
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    memberPubkey: String,
    isActive: Bool = true,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) throws {
    self.storageID = Self.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      memberPubkey: memberPubkey
    )
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.memberPubkeyHash = LocalDataCrypto.shared.digestHex(memberPubkey)
    self.encryptedMemberPubkey =
      try LocalDataCrypto.shared.encryptString(memberPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.isActive = isActive
    self.updatedAt = updatedAt
    self.createdAt = createdAt
  }

  static func storageID(ownerPubkey: String, sessionID: String, memberPubkey: String) -> String {
    let digest = LocalDataCrypto.shared.digestHex("\(sessionID):\(memberPubkey)")
    return "\(ownerPubkey):\(digest)"
  }

  func apply(isActive: Bool, updatedAt: Date) {
    self.isActive = isActive
    self.updatedAt = updatedAt
  }

  func memberMatches(_ pubkeyHex: String) -> Bool {
    memberPubkeyHash == LocalDataCrypto.shared.digestHex(pubkeyHex)
  }
}

@Model
final class SessionMemberIntervalEntity {
  @Attribute(.unique) var storageID: String
  var ownerPubkey: String
  var sessionID: String
  var memberPubkeyHash: String
  var encryptedMemberPubkey: String
  var startAt: Date
  var endAt: Date?

  var memberPubkey: String {
    LocalDataCrypto.shared.decryptString(encryptedMemberPubkey, ownerPubkey: ownerPubkey) ?? ""
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    memberPubkey: String,
    startAt: Date,
    endAt: Date? = nil
  ) throws {
    self.storageID = Self.storageID(ownerPubkey: ownerPubkey)
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.memberPubkeyHash = LocalDataCrypto.shared.digestHex(memberPubkey)
    self.encryptedMemberPubkey =
      try LocalDataCrypto.shared.encryptString(memberPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.startAt = startAt
    self.endAt = endAt
  }

  static func storageID(ownerPubkey: String) -> String {
    "\(ownerPubkey):\(UUID().uuidString.lowercased())"
  }

  func contains(_ timestamp: Date) -> Bool {
    guard startAt <= timestamp else { return false }
    if let endAt {
      return timestamp < endAt
    }
    return true
  }
}

@Model
final class SessionReactionEntity {
  @Attribute(.unique) var storageID: String
  var ownerPubkey: String
  var sessionID: String
  var postID: String
  var emoji: String
  var senderPubkeyHash: String
  var encryptedSenderPubkey: String
  var isActive: Bool
  var updatedAt: Date

  var senderPubkey: String {
    LocalDataCrypto.shared.decryptString(encryptedSenderPubkey, ownerPubkey: ownerPubkey) ?? ""
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    emoji: String,
    senderPubkey: String,
    isActive: Bool,
    updatedAt: Date = .now
  ) throws {
    self.storageID = Self.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      postID: postID,
      emoji: emoji,
      senderPubkey: senderPubkey
    )
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.postID = postID
    self.emoji = emoji
    self.senderPubkeyHash = LocalDataCrypto.shared.digestHex(senderPubkey)
    self.encryptedSenderPubkey =
      try LocalDataCrypto.shared.encryptString(senderPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.isActive = isActive
    self.updatedAt = updatedAt
  }

  static func storageID(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    emoji: String,
    senderPubkey: String
  ) -> String {
    let digest = LocalDataCrypto.shared.digestHex("\(sessionID):\(postID):\(emoji):\(senderPubkey)")
    return "\(ownerPubkey):\(digest)"
  }

  func senderMatches(_ pubkeyHex: String) -> Bool {
    senderPubkeyHash == LocalDataCrypto.shared.digestHex(pubkeyHex)
  }
}
