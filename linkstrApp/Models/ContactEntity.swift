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
  var nostrProfileName: String?
  var profileMetadataUpdatedAt: Date?
  var profileMetadataEventID: String?

  var profileSnapshot: KnownProfileSnapshot? {
    get {
      guard let updatedAt = profileMetadataUpdatedAt else { return nil }
      return KnownProfileSnapshot(
        chosenName: nostrProfileName, updatedAt: updatedAt, eventID: profileMetadataEventID
      )
    }
    set {
      nostrProfileName = newValue?.chosenName
      profileMetadataUpdatedAt = newValue?.updatedAt
      profileMetadataEventID = newValue?.eventID
    }
  }

  @Transient private var _localAlias: String??
  var localAlias: String? {
    if let cached = _localAlias { return cached }
    guard
      let decrypted = LocalDataCrypto.shared.decryptString(encryptedAlias, ownerPubkey: ownerPubkey)
    else { return nil }
    let trimmed = decrypted.trimmingCharacters(in: .whitespacesAndNewlines)
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
    localAlias ?? nostrProfileName ?? npub
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
    if !encryptedAlias.isEmpty {
      try LocalDataCrypto.shared.requireExistingKey(ownerPubkey: ownerPubkey)
    }
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

  func restoreEncryptedAlias(_ encryptedAlias: String) {
    self.encryptedAlias = encryptedAlias
    _localAlias = nil
  }
}
