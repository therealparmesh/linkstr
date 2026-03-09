import Foundation
import NostrSDK

struct KnownProfileSnapshot: Equatable {
  let chosenName: String?
  let updatedAt: Date
  let eventID: String?
}

struct LinkstrResolvedIdentity: Equatable {
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
    npub.localizedCaseInsensitiveCompare(displayName) != .orderedSame
  }

  init(localAlias: String?, chosenName: String?, pubkeyHex: String) {
    let normalizedAlias = localAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedChosenName = NostrProfileMetadata.normalizedChosenName(chosenName)
    let resolvedNPub =
      PublicKey(
        hex: NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
      )?.npub ?? pubkeyHex

    self.chosenName = normalizedChosenName
    npub = resolvedNPub

    let aliasValue = normalizedAlias?.isEmpty == false ? normalizedAlias : nil
    if let aliasValue {
      displayName = aliasValue
    } else if let normalizedChosenName {
      displayName = normalizedChosenName
    } else {
      displayName = resolvedNPub
    }
  }
}
