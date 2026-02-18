import Foundation
import SwiftData

enum SessionMessageKind: String, Codable {
  case root
  case reply
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
    get { SessionMessageKind(rawValue: kindRaw) ?? .reply }
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
