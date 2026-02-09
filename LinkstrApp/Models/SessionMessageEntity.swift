import Foundation
import SwiftData

enum SessionMessageKind: String, Codable {
  case root
  case reply
}

enum LinkType: String, Codable, CaseIterable {
  case tiktok
  case instagram
  case facebook
  case youtube
  case rumble
  case twitter
  case generic
}

@Model
final class SessionMessageEntity {
  @Attribute(.unique) var eventID: String
  var conversationID: String
  var rootID: String
  var kindRaw: String
  var senderPubkey: String
  var receiverPubkey: String
  var url: String?
  var note: String?
  var timestamp: Date
  var isArchived: Bool
  var readAt: Date?
  var linkTypeRaw: String
  var thumbnailURL: String?
  var metadataTitle: String?
  var cachedMediaPath: String?
  var cachedMediaSourceURL: String?

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
  ) {
    self.eventID = eventID
    self.conversationID = conversationID
    self.rootID = rootID
    self.kindRaw = kind.rawValue
    self.senderPubkey = senderPubkey
    self.receiverPubkey = receiverPubkey
    self.url = url
    self.note = note
    self.timestamp = timestamp
    self.isArchived = isArchived
    self.readAt = readAt
    self.linkTypeRaw = linkType.rawValue
    self.thumbnailURL = thumbnailURL
    self.metadataTitle = metadataTitle
    self.cachedMediaPath = cachedMediaPath
    self.cachedMediaSourceURL = cachedMediaSourceURL
  }
}
