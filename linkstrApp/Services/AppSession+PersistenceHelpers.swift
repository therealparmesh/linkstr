import Foundation
import NostrSDK
import SwiftData

// MARK: - Persistence Helpers

extension AppSession {
  func normalizedSessionName(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  func hasDeletedSession(ownerPubkey: String, sessionID: String) throws -> Bool {
    try messageStore.sessionDeletionTombstone(sessionID: sessionID, ownerPubkey: ownerPubkey) != nil
  }

  func sessionDeletionAuthorityPubkey(ownerPubkey: String, sessionID: String) throws -> String? {
    if let tombstone = try messageStore.sessionDeletionTombstone(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey
    ) {
      return tombstone.deletedByPubkey
    }
    return try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)?.createdByPubkey
  }

  func validatedReactionInputs(
    _ incoming: ReceivedDirectMessage
  ) -> ValidatedReactionInputs? {
    guard let isActive = incoming.payload.reactionActive else { return nil }
    let emoji = incoming.payload.emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !emoji.isEmpty else { return nil }
    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return nil }
    let postID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !postID.isEmpty else { return nil }
    return ValidatedReactionInputs(
      sessionID: sessionID, postID: postID, emoji: emoji, isActive: isActive)
  }
}

// MARK: - Inbound Session & Membership Resolution

extension AppSession {
  func resolveInboundSession(
    ownerPubkey: String,
    sessionID: String,
    senderPubkey: String,
    timestamp: Date,
    source: DirectMessageIngestSource
  ) -> InboundSessionResolution {
    do {
      if try hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) {
        return .ignored
      }
      guard let session = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)
      else {
        return .pending
      }
      guard
        inboundMembershipIsActive(
          sessionID: sessionID,
          senderPubkey: senderPubkey,
          timestamp: timestamp,
          source: source
        )
      else {
        if source == .live, session.membershipStateUpdatedAt.map({ $0 <= timestamp }) != false {
          return .pending
        }
        return .ignored
      }
      return .ready(session)
    } catch {
      report(error: error)
      return .ignored
    }
  }

  func inboundMembershipIsActive(
    sessionID: String,
    senderPubkey: String,
    timestamp: Date,
    source: DirectMessageIngestSource
  ) -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else { return false }
    let myPubkey = ownerPubkey

    do {
      if source == .live {
        guard
          try cachedIsMemberActive(
            sessionID: sessionID,
            ownerPubkey: ownerPubkey,
            memberPubkey: senderPubkey,
            at: .now
          )
        else {
          return false
        }
        guard
          try cachedIsMemberActive(
            sessionID: sessionID,
            ownerPubkey: ownerPubkey,
            memberPubkey: myPubkey,
            at: .now
          )
        else {
          return false
        }
      }
      guard
        try cachedIsMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: senderPubkey,
          at: timestamp
        )
      else {
        return false
      }
      guard
        try cachedIsMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: myPubkey,
          at: timestamp
        )
      else {
        return false
      }
      return true
    } catch {
      report(error: error)
      return false
    }
  }
}

// MARK: - Member Interval Cache

extension AppSession {
  func invalidateMemberIntervalCache() {
    memberIntervalCache.removeAll()
    memberIntervalCacheLegacy.removeAll()
  }

  func invalidateMemberIntervalCache(sessionID: String) {
    let keysToRemove = memberIntervalCache.keys.filter { $0.hasPrefix("\(sessionID):") }
    for key in keysToRemove { memberIntervalCache.removeValue(forKey: key) }
    let legacyKeysToRemove = memberIntervalCacheLegacy.keys.filter {
      $0.hasPrefix("\(sessionID):")
    }
    for key in legacyKeysToRemove { memberIntervalCacheLegacy.removeValue(forKey: key) }
  }

  func cachedMemberIntervals(
    sessionID: String,
    ownerPubkey: String,
    memberPubkeyHash: String
  ) throws -> [SessionMemberIntervalEntity] {
    let cacheKey = "\(sessionID):\(memberPubkeyHash)"
    if let cached = memberIntervalCache[cacheKey] {
      return cached
    }
    let intervals = try messageStore.memberIntervals(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      memberPubkeyHash: memberPubkeyHash
    )
    memberIntervalCache[cacheKey] = intervals
    return intervals
  }

  func cachedLegacyMember(
    sessionID: String,
    ownerPubkey: String,
    memberPubkeyHash: String
  ) throws -> SessionMemberEntity? {
    let cacheKey = "\(sessionID):\(memberPubkeyHash)"
    if let cached = memberIntervalCacheLegacy[cacheKey] {
      return cached
    }
    let allMembers = try messageStore.members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: false
    )
    for member in allMembers {
      let memberKey = "\(sessionID):\(member.memberPubkeyHash)"
      memberIntervalCacheLegacy[memberKey] = member
    }
    if memberIntervalCacheLegacy[cacheKey] == nil {
      memberIntervalCacheLegacy[cacheKey] = .some(nil)
    }
    return memberIntervalCacheLegacy[cacheKey] ?? nil
  }

  func cachedIsMemberActive(
    sessionID: String,
    ownerPubkey: String,
    memberPubkey: String,
    at timestamp: Date
  ) throws -> Bool {
    guard let normalizedMemberPubkey = NostrValueNormalizer.normalizedPubkeyHex(memberPubkey) else {
      throw NostrServiceError.invalidPubkey
    }
    let memberHash = LocalDataCrypto.shared.digestHex(normalizedMemberPubkey)
    let intervals = try cachedMemberIntervals(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      memberPubkeyHash: memberHash
    )
    if let matchingInterval = intervals.last(where: { $0.contains(timestamp) }) {
      return matchingInterval.memberPubkey == normalizedMemberPubkey
    }

    guard
      let legacyMember = try cachedLegacyMember(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        memberPubkeyHash: memberHash
      )
    else {
      return false
    }
    guard legacyMember.updatedAt <= timestamp else { return false }
    return legacyMember.isActive
  }
}
