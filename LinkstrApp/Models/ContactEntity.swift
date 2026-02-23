import Foundation
import NostrSDK
import SwiftData

@Model
final class ContactEntity {
  var ownerPubkey: String
  var targetPubkey: String
  var encryptedAlias: String
  var createdAt: Date

  var localAlias: String? {
    let decrypted = LocalDataCrypto.shared.decryptString(encryptedAlias, ownerPubkey: ownerPubkey)
    let trimmed = decrypted?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  var npub: String {
    PublicKey(hex: targetPubkey)?.npub ?? targetPubkey
  }

  var displayName: String {
    localAlias ?? npub
  }

  init(ownerPubkey: String, targetPubkey: String, alias: String? = nil, createdAt: Date = .now)
    throws
  {
    self.ownerPubkey = ownerPubkey
    self.targetPubkey = targetPubkey
    self.encryptedAlias = ""
    self.createdAt = createdAt
    try updateAlias(alias)
  }

  func updateAlias(_ alias: String?) throws {
    let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      encryptedAlias = ""
      return
    }
    encryptedAlias =
      try LocalDataCrypto.shared.encryptString(trimmed, ownerPubkey: ownerPubkey) ?? ""
  }

  func matchesTargetPubkey(_ pubkeyHex: String) -> Bool {
    targetPubkey == pubkeyHex
  }
}
