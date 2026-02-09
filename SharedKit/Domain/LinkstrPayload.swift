import Foundation

enum LinkstrPayloadKind: String, Codable {
  case root
  case reply
}

struct LinkstrPayload: Codable, Hashable {
  let conversationID: String
  let rootID: String
  let kind: LinkstrPayloadKind
  let url: String?
  let note: String?
  let timestamp: Int64

  enum CodingKeys: String, CodingKey {
    case conversationID = "conversation_id"
    case rootID = "root_id"
    case kind
    case url
    case note
    case timestamp
  }

  init(
    conversationID: String,
    rootID: String,
    kind: LinkstrPayloadKind,
    url: String?,
    note: String?,
    timestamp: Int64
  ) {
    self.conversationID = conversationID
    self.rootID = rootID
    self.kind = kind
    self.url = url
    self.note = note
    self.timestamp = timestamp
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conversationID = try container.decode(String.self, forKey: .conversationID)
    rootID = try container.decode(String.self, forKey: .rootID)
    kind = try container.decode(LinkstrPayloadKind.self, forKey: .kind)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    note = try container.decodeIfPresent(String.self, forKey: .note)
    // Older payloads may omit timestamp; accept and default to "now".
    timestamp =
      try container.decodeIfPresent(Int64.self, forKey: .timestamp)
      ?? Int64(Date.now.timeIntervalSince1970)
  }

  func validated() throws {
    switch kind {
    case .root:
      guard let url, URL(string: url) != nil else {
        throw LinkstrPayloadError.invalidRootURL
      }
    case .reply:
      guard url == nil else {
        throw LinkstrPayloadError.replyContainsURL
      }
    }
  }
}

enum LinkstrPayloadError: Error, LocalizedError {
  case invalidRootURL
  case replyContainsURL

  var errorDescription: String? {
    switch self {
    case .invalidRootURL:
      return "Post requires a valid URL."
    case .replyContainsURL:
      return "Reply messages cannot contain a URL."
    }
  }
}
