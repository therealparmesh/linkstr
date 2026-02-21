import Foundation
import NostrSDK

enum LinkstrPayloadKind: String, Codable {
  case root
  case reply
  case sessionCreate = "session_create"
  case sessionMembers = "session_members"
  case reaction
}

struct LinkstrPayload: Codable, Hashable {
  let conversationID: String
  let rootID: String
  let kind: LinkstrPayloadKind
  let url: String?
  let note: String?
  let timestamp: Int64
  let sessionName: String?
  let memberPubkeys: [String]?
  let emoji: String?
  let reactionActive: Bool?

  enum CodingKeys: String, CodingKey {
    case conversationID = "conversation_id"
    case rootID = "root_id"
    case kind
    case url
    case note
    case timestamp
    case sessionName = "session_name"
    case memberPubkeys = "member_pubkeys"
    case emoji
    case reactionActive = "reaction_active"
  }

  init(
    conversationID: String,
    rootID: String,
    kind: LinkstrPayloadKind,
    url: String?,
    note: String?,
    timestamp: Int64,
    sessionName: String? = nil,
    memberPubkeys: [String]? = nil,
    emoji: String? = nil,
    reactionActive: Bool? = nil
  ) {
    self.conversationID = conversationID
    self.rootID = rootID
    self.kind = kind
    self.url = url
    self.note = note
    self.timestamp = timestamp
    self.sessionName = sessionName
    self.memberPubkeys = memberPubkeys
    self.emoji = emoji
    self.reactionActive = reactionActive
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conversationID = try container.decode(String.self, forKey: .conversationID)
    rootID = try container.decode(String.self, forKey: .rootID)
    kind = try container.decode(LinkstrPayloadKind.self, forKey: .kind)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    note = try container.decodeIfPresent(String.self, forKey: .note)
    timestamp =
      try container.decodeIfPresent(Int64.self, forKey: .timestamp)
      ?? Int64(Date.now.timeIntervalSince1970)
    sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
    memberPubkeys = try container.decodeIfPresent([String].self, forKey: .memberPubkeys)
    emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
    reactionActive = try container.decodeIfPresent(Bool.self, forKey: .reactionActive)
  }

  func validated() throws {
    let sessionID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else {
      throw LinkstrPayloadError.invalidSessionID
    }

    switch kind {
    case .root:
      guard let url, LinkstrURLValidator.normalizedWebURL(from: url) != nil else {
        throw LinkstrPayloadError.invalidRootURL
      }
    case .reply:
      guard url == nil else {
        throw LinkstrPayloadError.replyContainsURL
      }
      let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmedNote.isEmpty else {
        throw LinkstrPayloadError.emptyReply
      }
    case .sessionCreate:
      let trimmedName = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmedName.isEmpty else {
        throw LinkstrPayloadError.invalidSessionName
      }
      guard let memberPubkeys = normalizedMemberPubkeys(), !memberPubkeys.isEmpty else {
        throw LinkstrPayloadError.invalidMembers
      }
    case .sessionMembers:
      guard let memberPubkeys = normalizedMemberPubkeys(), !memberPubkeys.isEmpty else {
        throw LinkstrPayloadError.invalidMembers
      }
    case .reaction:
      let trimmedRootID = rootID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedRootID.isEmpty else {
        throw LinkstrPayloadError.invalidRootID
      }
      let trimmedEmoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmedEmoji.isEmpty else {
        throw LinkstrPayloadError.invalidReactionEmoji
      }
      guard reactionActive != nil else {
        throw LinkstrPayloadError.invalidReactionState
      }
    }
  }

  func normalizedMemberPubkeys() -> [String]? {
    guard let memberPubkeys else { return nil }
    var seen = Set<String>()
    var normalized: [String] = []
    for candidate in memberPubkeys {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let publicKey = PublicKey(hex: trimmed) else {
        return nil
      }
      let normalizedHex = publicKey.hex
      guard !seen.contains(normalizedHex) else { continue }
      seen.insert(normalizedHex)
      normalized.append(normalizedHex)
    }
    return normalized
  }
}

enum LinkstrPayloadError: Error, LocalizedError {
  case invalidSessionID
  case invalidRootURL
  case replyContainsURL
  case emptyReply
  case invalidSessionName
  case invalidMembers
  case invalidRootID
  case invalidReactionEmoji
  case invalidReactionState

  var errorDescription: String? {
    switch self {
    case .invalidSessionID:
      return "Invalid session identifier."
    case .invalidRootURL:
      return "Post requires a valid URL."
    case .replyContainsURL:
      return "Reply messages cannot contain a URL."
    case .emptyReply:
      return "Reply cannot be empty."
    case .invalidSessionName:
      return "Session requires a name."
    case .invalidMembers:
      return "Session requires valid members."
    case .invalidRootID:
      return "Reaction requires a post identifier."
    case .invalidReactionEmoji:
      return "Reaction requires an emoji."
    case .invalidReactionState:
      return "Reaction requires an active/inactive state."
    }
  }
}
