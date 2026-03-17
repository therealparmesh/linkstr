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
  var publishedTransportEventIDsStorage: String?

  @Transient private var _senderPubkey: String?
  var senderPubkey: String {
    if let cached = _senderPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedSenderPubkey, ownerPubkey: ownerPubkey) ?? ""
    _senderPubkey = value
    return value
  }

  @Transient private var _receiverPubkey: String?
  var receiverPubkey: String {
    if let cached = _receiverPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedReceiverPubkey, ownerPubkey: ownerPubkey) ?? ""
    _receiverPubkey = value
    return value
  }

  @Transient private var _url: String??
  var url: String? {
    if let cached = _url { return cached }
    let value = LocalDataCrypto.shared.decryptString(encryptedURL, ownerPubkey: ownerPubkey)
    _url = .some(value)
    return value
  }

  @Transient private var _note: String??
  var note: String? {
    if let cached = _note { return cached }
    let value = LocalDataCrypto.shared.decryptString(encryptedNote, ownerPubkey: ownerPubkey)
    _note = .some(value)
    return value
  }

  @Transient private var _thumbnailURL: String??
  var thumbnailURL: String? {
    if let cached = _thumbnailURL { return cached }
    let value = LocalDataCrypto.shared.decryptString(
      encryptedThumbnailURL, ownerPubkey: ownerPubkey)
    _thumbnailURL = .some(value)
    return value
  }

  @Transient private var _metadataTitle: String??
  var metadataTitle: String? {
    if let cached = _metadataTitle { return cached }
    let value = LocalDataCrypto.shared.decryptString(
      encryptedMetadataTitle, ownerPubkey: ownerPubkey)
    _metadataTitle = .some(value)
    return value
  }

  var publishedTransportEventIDs: [String] {
    Self.normalizedTransportEventIDs(fromStorage: publishedTransportEventIDsStorage)
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
    receiverPubkey: String? = nil,
    url: String?,
    note: String?,
    timestamp: Date,
    isArchived: Bool = false,
    readAt: Date? = nil,
    linkType: LinkType,
    thumbnailURL: String? = nil,
    metadataTitle: String? = nil,
    cachedMediaPath: String? = nil,
    cachedMediaSourceURL: String? = nil,
    publishedTransportEventIDs: [String] = []
  ) throws {
    let crypto = LocalDataCrypto.shared
    let normalizedSenderPubkey =
      NostrValueNormalizer.normalizedPubkeyHex(senderPubkey)
      ?? senderPubkey.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedReceiverPubkey =
      NostrValueNormalizer.normalizedPubkeyHex(receiverPubkey ?? ownerPubkey)
      ?? (receiverPubkey ?? ownerPubkey).trimmingCharacters(in: .whitespacesAndNewlines)
    self.storageID = Self.storageID(ownerPubkey: ownerPubkey, eventID: eventID)
    self.eventID = eventID
    self.ownerPubkey = ownerPubkey
    self.conversationID = conversationID
    self.rootID = rootID
    self.kindRaw = kind.rawValue
    self.senderPubkeyHash = crypto.digestHex(normalizedSenderPubkey)
    self.receiverPubkeyHash = crypto.digestHex(resolvedReceiverPubkey)
    self.encryptedSenderPubkey =
      try crypto.encryptString(normalizedSenderPubkey, ownerPubkey: ownerPubkey) ?? ""
    self.encryptedReceiverPubkey =
      try crypto.encryptString(resolvedReceiverPubkey, ownerPubkey: ownerPubkey) ?? ""
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
    self.publishedTransportEventIDsStorage =
      Self.transportEventIDStorageValue(from: publishedTransportEventIDs)
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
      _metadataTitle = nil
      _thumbnailURL = nil
    } catch {
      encryptedMetadataTitle = previousEncryptedTitle
      encryptedThumbnailURL = previousEncryptedThumbnailURL
      throw error
    }
  }

  func senderMatches(_ pubkeyHex: String) -> Bool {
    senderPubkeyHash == LocalDataCrypto.shared.digestHex(pubkeyHex)
  }

  @discardableResult
  func appendPublishedTransportEventIDs(_ eventIDs: [String]) -> Bool {
    let next = Self.normalizedTransportEventIDs(
      publishedTransportEventIDs + eventIDs
    )
    let nextStorage = next.isEmpty ? nil : next.joined(separator: ",")
    guard nextStorage != publishedTransportEventIDsStorage else { return false }
    publishedTransportEventIDsStorage = nextStorage
    return true
  }

  private static func transportEventIDStorageValue(from eventIDs: [String]) -> String? {
    let normalized = normalizedTransportEventIDs(eventIDs)
    return normalized.isEmpty ? nil : normalized.joined(separator: ",")
  }

  private static func normalizedTransportEventIDs(_ candidates: [String]) -> [String] {
    NostrValueNormalizer.dedupedNormalizedEventIDs(candidates)
  }

  private static func normalizedTransportEventIDs(fromStorage storage: String?) -> [String] {
    guard let storage else { return [] }
    return normalizedTransportEventIDs(storage.split(separator: ",").map(String.init))
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
  var membershipStateUpdatedAt: Date?
  var membershipStateEventID: String?

  @Transient private var _name: String?
  var name: String {
    if let cached = _name { return cached }
    let value = LocalDataCrypto.shared.decryptString(encryptedName, ownerPubkey: ownerPubkey) ?? ""
    _name = value
    return value
  }

  @Transient private var _createdByPubkey: String?
  var createdByPubkey: String {
    if let cached = _createdByPubkey { return cached }
    let value =
      LocalDataCrypto.shared.decryptString(encryptedCreatedByPubkey, ownerPubkey: ownerPubkey) ?? ""
    _createdByPubkey = value
    return value
  }

  init(
    ownerPubkey: String,
    sessionID: String,
    name: String,
    createdByPubkey: String,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    isArchived: Bool = false,
    membershipStateUpdatedAt: Date? = nil,
    membershipStateEventID: String? = nil
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
    self.membershipStateUpdatedAt = membershipStateUpdatedAt
    self.membershipStateEventID = membershipStateEventID
  }

  static func storageID(ownerPubkey: String, sessionID: String) -> String {
    "\(ownerPubkey):\(sessionID)"
  }

  func updateName(_ name: String, updatedAt: Date) throws {
    let previousEncryptedName = encryptedName
    do {
      encryptedName = try LocalDataCrypto.shared.encryptString(name, ownerPubkey: ownerPubkey) ?? ""
      _name = nil
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

  func senderMatches(_ pubkeyHex: String) -> Bool {
    senderPubkeyHash == LocalDataCrypto.shared.digestHex(pubkeyHex)
  }
}

@Model
final class SessionPostDeletionEntity {
  @Attribute(.unique) var storageID: String
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

  func deletedByMatches(_ pubkeyHex: String) -> Bool {
    deletedByPubkeyHash == LocalDataCrypto.shared.digestHex(pubkeyHex)
  }
}
