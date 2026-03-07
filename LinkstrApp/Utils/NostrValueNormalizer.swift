import Foundation
import NostrSDK

enum NostrValueNormalizer {
  static func normalizedEventID(_ candidate: String?) -> String? {
    guard let candidate else { return nil }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func normalizedPubkeyHex(_ candidate: String) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let publicKey = PublicKey(hex: trimmed) else { return nil }
    return publicKey.hex
  }

  static func normalizedPubkeyHex(fromAnyPublicKeyString candidate: String) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if let publicKey = PublicKey(npub: trimmed) {
      return publicKey.hex
    }
    return normalizedPubkeyHex(trimmed)
  }

  static func dedupedNormalizedPubkeyHexes(_ candidates: [String]) -> [String] {
    var normalized: [String] = []
    var seen = Set<String>()

    for candidate in candidates {
      guard let normalizedHex = normalizedPubkeyHex(candidate) else { continue }
      guard seen.insert(normalizedHex).inserted else { continue }
      normalized.append(normalizedHex)
    }

    return normalized
  }

  static func validatedNormalizedPubkeyHexes(_ candidates: [String]) -> [String]? {
    var normalized: [String] = []
    var seen = Set<String>()

    for candidate in candidates {
      guard let normalizedHex = normalizedPubkeyHex(candidate) else {
        return nil
      }
      guard seen.insert(normalizedHex).inserted else { continue }
      normalized.append(normalizedHex)
    }

    return normalized
  }

  static func shouldApplyStateUpdate(
    currentUpdatedAt: Date?,
    currentEventID: String?,
    incomingUpdatedAt: Date,
    incomingEventID: String?
  ) -> Bool {
    guard let currentUpdatedAt else { return true }
    if incomingUpdatedAt > currentUpdatedAt { return true }
    if incomingUpdatedAt < currentUpdatedAt { return false }

    guard let incomingToken = normalizedEventID(incomingEventID) else {
      return false
    }

    guard let currentToken = normalizedEventID(currentEventID) else {
      return true
    }
    return incomingToken > currentToken
  }
}
