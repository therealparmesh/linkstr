import Foundation
import NostrSDK

extension LinkstrBackup {
  func merging(_ incoming: LinkstrBackup) throws -> LinkstrBackup {
    guard owner == incoming.owner else { throw BackupError.invalidFile }
    var result = self
    result.nsec = incoming.nsec
    result.settings = incoming.settings
    result.sessions = try merge(sessions, incoming.sessions, key: \.id) { local, remote in
      guard local.creator == remote.creator else { throw BackupError.conflict }
      var winner = Self.newerMembership(remote, than: local) ? remote : local
      winner.archived = local.archived
      winner.createdAt = min(local.createdAt, remote.createdAt)
      winner.updatedAt = max(local.updatedAt, remote.updatedAt)
      return winner
    }
    result.posts = try merge(posts, incoming.posts, key: \.id) { local, remote in
      guard local.sessionID == remote.sessionID, local.sender == remote.sender,
        local.receiver == remote.receiver, local.url == remote.url, local.note == remote.note,
        local.timestamp == remote.timestamp else { throw BackupError.conflict }
      var post = local
      post.readAt = local.readAt ?? remote.readAt
      post.transportIDs = Array(Set(local.transportIDs + remote.transportIDs)).sorted()
      return post
    }
    result.mergeMembership(local: self, incoming: incoming)
    result.reactions = merge(reactions, incoming.reactions, key: \.id) {
      Self.newerState($1.updatedAt, $1.eventID, than: $0.updatedAt, $0.eventID) ? $1 : $0
    }
    result.deletions = try merge(deletions, incoming.deletions, key: \.id) {
      guard $0.pubkey == $1.pubkey else { throw BackupError.conflict }
      return Self.newerState($1.updatedAt, $1.eventID, than: $0.updatedAt, $0.eventID) ? $1 : $0
    }
    result.mergeContacts(local: self, incoming: incoming)
    result.follows = merge(follows, incoming.follows, key: \.pubkey) {
      Self.newerReplaceable($1.updatedAt, $1.eventID, than: $0.updatedAt, $0.eventID) ? $1 : $0
    }
    try result.mergePreferences(local: self, incoming: incoming)
    try result.applyDeletions()
    return result
  }

  private static func newerMembership(_ incoming: Session, than local: Session) -> Bool {
    newerState(incoming.membershipDate ?? incoming.createdAt, incoming.membershipID,
               than: local.membershipDate, local.membershipID)
  }

  static func newerState(_ date: Date, _ id: String?, than previous: Date?, _ previousID: String?) -> Bool {
    NostrValueNormalizer.shouldApplyStateUpdate(
      currentUpdatedAt: previous, currentEventID: previousID, incomingUpdatedAt: date, incomingEventID: id)
  }

  static func newerReplaceable(_ date: Date, _ id: String?, than previous: Date?, _ previousID: String?) -> Bool {
    NostrValueNormalizer.shouldApplyReplaceableEvent(
      currentUpdatedAt: previous, currentEventID: previousID, incomingUpdatedAt: date, incomingEventID: id)
  }

  private func merge<Value>(
    _ local: [Value], _ incoming: [Value], key: KeyPath<Value, String>,
    combine: (Value, Value) throws -> Value
  ) rethrows -> [Value] {
    var records = Dictionary(uniqueKeysWithValues: local.map { ($0[keyPath: key], $0) })
    for value in incoming {
      let id = value[keyPath: key]
      records[id] = try records[id].map { try combine($0, value) } ?? value
    }
    return records.sorted { $0.key < $1.key }.map(\.value)
  }

  private mutating func mergeMembership(local: LinkstrBackup, incoming: LinkstrBackup) {
    let oldSessions = Dictionary(uniqueKeysWithValues: local.sessions.map { ($0.id, $0) })
    let newSessions = Dictionary(uniqueKeysWithValues: incoming.sessions.map { ($0.id, $0) })
    var selected = Dictionary(uniqueKeysWithValues: local.members.map { ($0.id, $0) })
    for member in incoming.members where selected[member.id] == nil { selected[member.id] = member }
    let oldMembers = Dictionary(grouping: local.members, by: \.sessionID)
    let newMembers = Dictionary(grouping: incoming.members, by: \.sessionID)
    let selectedBySession = Dictionary(grouping: selected.values, by: \.sessionID)
    members = []
    for session in sessions {
      let useIncoming = newSessions[session.id].map { remote in
        oldSessions[session.id].map { Self.newerMembership(remote, than: $0) } ?? true
      } ?? false
      let winners = useIncoming ? newMembers[session.id, default: []] : oldMembers[session.id, default: []]
      let winnerByKey = Dictionary(uniqueKeysWithValues: winners.map { ($0.pubkey, $0) })
      for var member in selectedBySession[session.id, default: []] {
        member.active = false
        if let winner = winnerByKey[member.pubkey] { member = winner }
        members.append(member)
      }
    }
    intervals = Self.mergeIntervals(local.intervals + incoming.intervals)
  }

  private static func mergeIntervals(_ values: [Interval]) -> [Interval] {
    struct Key: Hashable { let session: String; let pubkey: String; let start: Date }
    var records: [Key: Interval] = [:]
    for value in values {
      let key = Key(session: value.sessionID, pubkey: value.pubkey, start: value.start)
      var merged = value
      if let oldEnd = records[key]?.end { merged.end = min(oldEnd, value.end ?? oldEnd) }
      records[key] = merged
    }
    let groups = Dictionary(grouping: Array(records.values)) { "\($0.sessionID):\($0.pubkey)" }
    return groups.values.flatMap { group in
      let ends = group.compactMap(\.end).sorted()
      var boundary = 0
      return group.sorted { $0.start < $1.start }.map { interval in
        var result = interval
        while boundary < ends.count, ends[boundary] <= interval.start { boundary += 1 }
        if boundary < ends.count { result.end = min(result.end ?? ends[boundary], ends[boundary]) }
        return result
      }
    }
  }

  private mutating func mergeContacts(local: LinkstrBackup, incoming: LinkstrBackup) {
    let takeFollows = incoming.account?.followDate.map {
      Self.newerReplaceable($0, incoming.account?.followID,
                            than: local.account?.followDate, local.account?.followID)
    } ?? (local.account?.followDate == nil && local.contacts.isEmpty)
    let takeProfile = incoming.account?.profileDate.map {
      Self.newerReplaceable($0, incoming.account?.profileID,
                            than: local.account?.profileDate, local.account?.profileID)
    } ?? false
    account = local.account ?? incoming.account
    if takeFollows {
      account?.followDate = incoming.account?.followDate
      account?.followID = incoming.account?.followID
      account?.followTags = incoming.account?.followTags
    }
    if takeProfile {
      account?.profileName = incoming.account?.profileName
      account?.profileContent = incoming.account?.profileContent
      account?.profileDate = incoming.account?.profileDate
      account?.profileID = incoming.account?.profileID
    }
    let retained = Set((takeFollows ? incoming.contacts : local.contacts).map(\.pubkey))
    contacts = merge(local.contacts, incoming.contacts, key: \.pubkey) { old, new in
      var contact = old
      contact.alias = old.alias ?? new.alias
      if let date = new.profileDate,
        Self.newerReplaceable(date, new.profileID, than: old.profileDate, old.profileID) {
        contact.profileName = new.profileName
        contact.profileDate = date
        contact.profileID = new.profileID
      }
      return contact
    }.filter { retained.contains($0.pubkey) }
  }

  private mutating func mergePreferences(local: LinkstrBackup, incoming: LinkstrBackup) throws {
    guard let keypair = Keypair(nsec: nsec) else { throw IdentityError.invalidNsec }
    let codec = PrivatePreferenceCodec()
    struct Winner { var record: Preference; let event: NostrEvent; let value: PrivatePreference }
    var winners: [String: Winner] = [:]
    for record in local.preferences + incoming.preferences {
      let event = try JSONDecoder().decode(NostrEvent.self, from: record.event)
      let value = try codec.preference(from: event, keypair: keypair)
      var record = record
      if let old = winners[value.key] {
        if old.event.id == event.id {
          record.pending = old.record.pending && record.pending
        } else if !Self.newerReplaceable(event.createdDate, event.id, than: old.event.createdDate, old.event.id) {
          continue
        }
      }
      winners[value.key] = Winner(record: record, event: event, value: value)
    }
    preferences = winners.values.map { $0.record }
    let contactIndices = Dictionary(uniqueKeysWithValues: contacts.indices.map { (contacts[$0].pubkey, $0) })
    let sessionIndices = Dictionary(uniqueKeysWithValues: sessions.indices.map { (sessions[$0].id, $0) })
    for winner in winners.values {
      switch winner.value {
      case .alias(let pubkey, let name):
        if let index = contactIndices[pubkey] { contacts[index].alias = name }
      case .archive(let sessionID, let archived):
        if let index = sessionIndices[sessionID] { sessions[index].archived = archived }
      }
    }
  }

  private mutating func applyDeletions() throws {
    let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    let postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
    var deletedSessions = Set<String>()
    var deletedPosts = Set<String>()
    for deletion in deletions {
      if let postID = deletion.postID {
        if let post = postsByID[postID] {
          guard post.sender == deletion.pubkey, post.sessionID == deletion.sessionID else {
            throw BackupError.conflict
          }
        }
        deletedPosts.insert(postID)
      } else {
        if let session = sessionsByID[deletion.sessionID], session.creator != deletion.pubkey {
          throw BackupError.conflict
        }
        deletedSessions.insert(deletion.sessionID)
      }
    }
    sessions.removeAll { deletedSessions.contains($0.id) }
    posts.removeAll { deletedSessions.contains($0.sessionID) || deletedPosts.contains($0.id) }
    members.removeAll { deletedSessions.contains($0.sessionID) }
    intervals.removeAll { deletedSessions.contains($0.sessionID) }
    reactions.removeAll { deletedSessions.contains($0.sessionID) || deletedPosts.contains($0.postID) }
  }
}
