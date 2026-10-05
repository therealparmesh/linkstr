import Foundation
import NostrSDK

extension LinkstrBackup {
  static let maximumFileBytes = 128 * 1_024 * 1_024

  func validate() throws {
    guard let keypair = Keypair(nsec: nsec) else { throw IdentityError.invalidNsec }
    guard version <= 1 else { throw BackupError.newerVersion }
    guard version == 1, owner == keypair.publicKey.hex else { throw BackupError.invalidFile }
    let count = sessions.count + posts.count + members.count + intervals.count + reactions.count
      + deletions.count + contacts.count + follows.count + preferences.count
    guard count <= 250_000, settings.relays.count <= 100 else { throw BackupError.tooLarge }
    try unique(sessions.map(\.id))
    try unique(posts.map(\.id))
    try unique(members.map(\.id))
    try unique(reactions.map(\.id))
    try unique(deletions.map(\.id))
    try unique(contacts.map(\.pubkey))
    try unique(follows.map(\.pubkey))
    try unique(settings.relays.map(\.url))
    try validateContent()
    try validateRelationships(keypair: keypair)
  }

  private func validateContent() throws {
    let sessionIDs = Set(sessions.map(\.id))
    let postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
    for session in sessions {
      try publicKey(session.creator)
      guard !session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackupError.invalidFile
      }
    }
    for post in posts {
      try publicKey(post.sender)
      try publicKey(post.receiver)
      guard sessionIDs.contains(post.sessionID), LinkstrURLValidator.normalizedWebURL(from: post.url) == post.url
      else { throw BackupError.invalidFile }
      try unique(post.transportIDs)
    }
    for member in members {
      try publicKey(member.pubkey)
      guard sessionIDs.contains(member.sessionID) else { throw BackupError.invalidFile }
    }
    for interval in intervals {
      try publicKey(interval.pubkey)
      guard sessionIDs.contains(interval.sessionID), interval.end.map({ $0 >= interval.start }) != false
      else { throw BackupError.invalidFile }
    }
    for reaction in reactions {
      try publicKey(reaction.pubkey)
      guard postsByID[reaction.postID]?.sessionID == reaction.sessionID, !reaction.emoji.isEmpty
      else { throw BackupError.invalidFile }
    }
  }

  private func validateRelationships(keypair: Keypair) throws {
    for deletion in deletions {
      try publicKey(deletion.pubkey)
      try identifier(deletion.sessionID)
      if let postID = deletion.postID { try identifier(postID) }
    }
    for contact in contacts { try publicKey(contact.pubkey) }
    for follow in follows { try publicKey(follow.pubkey) }
    guard settings.customRelays || settings.relays.isEmpty else { throw BackupError.invalidFile }
    for relay in settings.relays {
      guard let url = URL(string: relay.url), ["ws", "wss"].contains(url.scheme?.lowercased()),
        url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw BackupError.invalidFile }
    }
    if let tags = account?.followTags { _ = try JSONDecoder().decode([Tag].self, from: tags) }
    let identifiers = try preferences.map { record -> String in
      let event = try JSONDecoder().decode(NostrEvent.self, from: record.event)
      let preference = try PrivatePreferenceCodec().preference(from: event, keypair: keypair)
      return preference.key
    }
    try unique(identifiers)
  }

  private func publicKey(_ value: String) throws {
    guard NostrValueNormalizer.normalizedPubkeyHex(value) == value else { throw BackupError.invalidFile }
  }

  private func identifier(_ value: String) throws {
    guard !value.isEmpty, value.count <= 1_024,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw BackupError.invalidFile }
  }

  private func unique(_ values: [String]) throws {
    guard Set(values).count == values.count else { throw BackupError.invalidFile }
    for value in values { try identifier(value) }
  }
}
