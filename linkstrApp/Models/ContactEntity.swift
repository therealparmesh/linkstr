import Foundation
import NostrSDK
import SwiftData

@Model
final class ContactEntity {
  var ownerPubkey: String
  var targetPubkey: String
  #Index<ContactEntity>([\.ownerPubkey, \.targetPubkey])

  var encryptedAlias: String
  var createdAt: Date

  @Transient private var _localAlias: String??
  var localAlias: String? {
    if let cached = _localAlias { return cached }
    let decrypted = LocalDataCrypto.shared.decryptString(encryptedAlias, ownerPubkey: ownerPubkey)
    let trimmed = decrypted?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let value: String? = trimmed.isEmpty ? nil : trimmed
    _localAlias = .some(value)
    return value
  }

  @Transient private var _npub: String?
  var npub: String {
    if let cached = _npub { return cached }
    let value = PublicKey(hex: targetPubkey)?.npub ?? targetPubkey
    _npub = value
    return value
  }

  var displayName: String {
    localAlias ?? npub
  }

  init(
    ownerPubkey: String,
    targetPubkey: String,
    alias: String? = nil,
    createdAt: Date = .now
  )
    throws {
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
      _localAlias = nil
      return
    }
    encryptedAlias =
      try LocalDataCrypto.shared.encryptString(trimmed, ownerPubkey: ownerPubkey) ?? ""
    _localAlias = nil
  }
}
