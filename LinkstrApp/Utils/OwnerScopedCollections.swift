import Foundation

enum OwnerScopedCollections {
  static func contacts(_ contacts: [ContactEntity], ownerPubkey: String?) -> [ContactEntity] {
    guard let ownerPubkey else { return [] }
    return
      contacts
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  static func messages(_ messages: [SessionMessageEntity], ownerPubkey: String?)
    -> [SessionMessageEntity]
  {
    guard let ownerPubkey else { return [] }
    return messages.filter { $0.ownerPubkey == ownerPubkey }
  }

  static func sessions(_ sessions: [SessionEntity], ownerPubkey: String?) -> [SessionEntity] {
    guard let ownerPubkey else { return [] }
    return
      sessions
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  static func members(_ members: [SessionMemberEntity], ownerPubkey: String?)
    -> [SessionMemberEntity]
  {
    guard let ownerPubkey else { return [] }
    return members.filter { $0.ownerPubkey == ownerPubkey }
  }

  static func reactions(
    _ reactions: [SessionReactionEntity],
    ownerPubkey: String?
  ) -> [SessionReactionEntity] {
    guard let ownerPubkey else { return [] }
    return reactions.filter { $0.ownerPubkey == ownerPubkey }
  }
}
