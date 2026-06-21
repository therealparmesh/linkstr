import Foundation
import SwiftData

@Model
final class SessionMemberEntity {
  @Attribute(.unique) var storageID: String
  #Index<SessionMemberEntity>([\.ownerPubkey, \.sessionID, \.isActive], [\.memberPubkeyHash])

  var ownerPubkey: String
  var sessionID: String
  var memberPubkeyHash: String
  var encryptedMemberPubkey: String
  var isActive: Bool
  var updatedAt: Date
  var createdAt: Date

  @Transient private var _memberPubkey: String?
  var memberPubkey: String {
    if let cached = _memberPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedMemberPubkey, ownerPubkey: ownerPubkey) ?? ""
    _memberPubkey = value
    return value
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

  func memberMatchesHash(_ precomputedHash: String) -> Bool {
    memberPubkeyHash == precomputedHash
  }
}

@Model
final class SessionMemberIntervalEntity {
  @Attribute(.unique) var storageID: String
  #Index<SessionMemberIntervalEntity>([\.ownerPubkey, \.sessionID])

  var ownerPubkey: String
  var sessionID: String
  var memberPubkeyHash: String
  var encryptedMemberPubkey: String
  var startAt: Date
  var endAt: Date?

  @Transient private var _memberPubkey: String?
  var memberPubkey: String {
    if let cached = _memberPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedMemberPubkey, ownerPubkey: ownerPubkey) ?? ""
    _memberPubkey = value
    return value
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
  #Index<SessionReactionEntity>([\.ownerPubkey, \.sessionID, \.postID], [\.senderPubkeyHash])

  var ownerPubkey: String
  var sessionID: String
  var postID: String
  var emoji: String
  var senderPubkeyHash: String
  var encryptedSenderPubkey: String
  var isActive: Bool
  var updatedAt: Date
  var lastEventID: String = ""

  @Transient private var _senderPubkey: String?
  var senderPubkey: String {
    if let cached = _senderPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedSenderPubkey, ownerPubkey: ownerPubkey) ?? ""
    _senderPubkey = value
    return value
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    emoji: String,
    senderPubkey: String,
    isActive: Bool,
    updatedAt: Date = .now,
    eventID: String = ""
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
    self.lastEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
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

  func senderMatchesHash(_ precomputedHash: String) -> Bool {
    senderPubkeyHash == precomputedHash
  }
}

@Model
final class SessionDeletionTombstoneEntity {
  @Attribute(.unique) var storageID: String
  #Index<SessionDeletionTombstoneEntity>([\.ownerPubkey, \.sessionID])

  var ownerPubkey: String
  var sessionID: String
  var deletedByPubkeyHash: String
  var encryptedDeletedByPubkey: String
  var updatedAt: Date
  var lastEventID: String = ""

  @Transient private var _deletedByPubkey: String?
  var deletedByPubkey: String {
    if let cached = _deletedByPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedDeletedByPubkey, ownerPubkey: ownerPubkey) ?? ""
    _deletedByPubkey = value
    return value
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    deletedByPubkey: String,
    updatedAt: Date = .now,
    eventID: String = ""
  ) throws {
    self.storageID = Self.storageID(ownerPubkey: ownerPubkey, sessionID: sessionID)
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.deletedByPubkeyHash = LocalDataCrypto.shared.digestHex(deletedByPubkey)
    self.encryptedDeletedByPubkey =
      try LocalDataCrypto.shared.encryptString(deletedByPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.updatedAt = updatedAt
    self.lastEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func storageID(ownerPubkey: String, sessionID: String) -> String {
    "\(ownerPubkey):\(sessionID)"
  }

}

@Model
final class SessionPostDeletionEntity {
  @Attribute(.unique) var storageID: String
  #Index<SessionPostDeletionEntity>([\.ownerPubkey, \.sessionID])

  var ownerPubkey: String
  var sessionID: String
  var rootID: String
  var deletedByPubkeyHash: String
  var encryptedDeletedByPubkey: String
  var updatedAt: Date
  var lastEventID: String = ""

  @Transient private var _deletedByPubkey: String?
  var deletedByPubkey: String {
    if let cached = _deletedByPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedDeletedByPubkey, ownerPubkey: ownerPubkey) ?? ""
    _deletedByPubkey = value
    return value
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    rootID: String,
    deletedByPubkey: String,
    updatedAt: Date = .now,
    eventID: String = ""
  ) throws {
    self.storageID = Self.storageID(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      rootID: rootID,
      deletedByPubkey: deletedByPubkey
    )
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.rootID = rootID
    self.deletedByPubkeyHash = LocalDataCrypto.shared.digestHex(deletedByPubkey)
    self.encryptedDeletedByPubkey =
      try LocalDataCrypto.shared.encryptString(deletedByPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.updatedAt = updatedAt
    self.lastEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func storageID(
    ownerPubkey: String,
    sessionID: String,
    rootID: String,
    deletedByPubkey: String
  ) -> String {
    let digest = LocalDataCrypto.shared.digestHex("\(sessionID):\(rootID):\(deletedByPubkey)")
    return "\(ownerPubkey):\(digest)"
  }

}
