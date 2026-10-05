import Foundation
import NostrSDK

struct LinkstrBackup: Codable, Sendable {
  var version = 1
  var createdAt = Date.now
  var nsec: String
  var owner: String
  var settings: Settings
  var account: Account?
  var sessions: [Session] = []
  var posts: [Post] = []
  var members: [Member] = []
  var intervals: [Interval] = []
  var reactions: [Reaction] = []
  var deletions: [Deletion] = []
  var contacts: [Contact] = []
  var follows: [Follow] = []
  var preferences: [Preference] = []

  struct Settings: Codable, Sendable {
    var loopLocalVideos: Bool
    var customRelays: Bool
    var relays: [Relay]
  }

  struct Relay: Codable, Sendable {
    var url: String
    var enabled: Bool
    var createdAt: Date
  }

  struct Account: Codable, Sendable {
    var followDate: Date?
    var followID: String?
    var followTags: Data?
    var profileName: String?
    var profileContent: String?
    var profileDate: Date?
    var profileID: String?
    var createdAt: Date
    var updatedAt: Date
  }

  struct Session: Codable, Sendable {
    var id: String
    var name: String
    var creator: String
    var createdAt: Date
    var updatedAt: Date
    var archived: Bool
    var membershipDate: Date?
    var membershipID: String?
  }

  struct Post: Codable, Sendable {
    var id: String
    var sessionID: String
    var sender: String
    var receiver: String
    var url: String
    var note: String?
    var timestamp: Date
    var archived: Bool
    var readAt: Date?
    var transportIDs: [String]
  }

  struct Member: Codable, Sendable {
    var sessionID: String
    var pubkey: String
    var active: Bool
    var createdAt: Date
    var updatedAt: Date
    var id: String { "\(sessionID):\(pubkey)" }
  }

  struct Interval: Codable, Sendable {
    var sessionID: String
    var pubkey: String
    var start: Date
    var end: Date?
  }

  struct Reaction: Codable, Sendable {
    var sessionID: String
    var postID: String
    var pubkey: String
    var emoji: String
    var active: Bool
    var updatedAt: Date
    var eventID: String
    var id: String { "\(sessionID):\(postID):\(pubkey):\(emoji)" }
  }

  struct Deletion: Codable, Sendable {
    var sessionID: String
    var postID: String?
    var pubkey: String
    var updatedAt: Date
    var eventID: String
    var id: String { "\(sessionID):\(postID ?? "")" }
  }

  struct Contact: Codable, Sendable {
    var pubkey: String
    var alias: String?
    var createdAt: Date
    var profileName: String?
    var profileDate: Date?
    var profileID: String?
  }

  struct Follow: Codable, Sendable {
    var pubkey: String
    var follows: Bool
    var updatedAt: Date
    var eventID: String
  }

  struct Preference: Codable, Sendable {
    var event: Data
    var pending: Bool
  }
}

enum BackupError: LocalizedError {
  case invalidFile
  case newerVersion
  case tooLarge
  case signedIn
  case unavailable
  case conflict

  var errorDescription: String? {
    switch self {
    case .invalidFile: return "this backup is damaged or contains invalid data."
    case .newerVersion: return "update linkstr to restore this backup."
    case .tooLarge: return "this backup is too large to restore on this device."
    case .signedIn: return "log out before restoring a backup."
    case .unavailable: return "backup is unavailable until local storage and account keys are ready."
    case .conflict: return "this backup conflicts with saved account data. nothing was restored."
    }
  }
}
