import Foundation
import NostrSDK

struct KnownProfileSnapshot: Equatable {
  let chosenName: String?
  let updatedAt: Date
  let eventID: String?
}

struct LinkstrResolvedIdentity: Equatable {
  let avatarName: String?
  let displayName: String
  let chosenName: String?
  let npub: String

  var aliasedChosenName: String? {
    guard let chosenName else { return nil }
    guard chosenName.localizedCaseInsensitiveCompare(displayName) != .orderedSame else {
      return nil
    }
    return chosenName
  }

  var showsNPubLine: Bool {
    avatarName != nil && npub.localizedCaseInsensitiveCompare(displayName) != .orderedSame
  }

  init(localAlias: String?, chosenName: String?, pubkeyHex: String, npub: String? = nil) {
    let normalizedAlias = localAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedChosenName = NostrProfileMetadata.normalizedChosenName(chosenName)
    let resolvedNPub =
      npub ?? PublicKey(
        hex: NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
      )?.npub ?? pubkeyHex

    self.chosenName = normalizedChosenName
    self.npub = resolvedNPub

    let aliasValue = normalizedAlias?.isEmpty == false ? normalizedAlias : nil
    avatarName = aliasValue ?? normalizedChosenName
    displayName = avatarName ?? Self.shortenedNPub(resolvedNPub)
  }

  static func shortenedNPub(_ npub: String) -> String {
    guard npub.count > 24 else { return npub }
    return "\(npub.prefix(12))…\(npub.suffix(8))"
  }
}
