import Foundation
import SwiftData

@Model
final class ContactEntity {
  var ownerPubkey: String
  var npubHash: String
  var encryptedNPub: String
  var encryptedDisplayName: String
  var createdAt: Date

  var npub: String {
    LocalDataCrypto.shared.decryptString(encryptedNPub, ownerPubkey: ownerPubkey) ?? ""
  }

  var displayName: String {
    LocalDataCrypto.shared.decryptString(encryptedDisplayName, ownerPubkey: ownerPubkey) ?? ""
  }

  init(ownerPubkey: String, npub: String, displayName: String, createdAt: Date = .now) throws {
    self.ownerPubkey = ownerPubkey
    self.npubHash = LocalDataCrypto.shared.digestHex(npub)
    self.encryptedNPub =
      try LocalDataCrypto.shared.encryptString(npub, ownerPubkey: ownerPubkey) ?? ""
    self.encryptedDisplayName =
      try LocalDataCrypto.shared.encryptString(displayName, ownerPubkey: ownerPubkey) ?? ""
    self.createdAt = createdAt
  }

  func updateSecureFields(npub: String, displayName: String) throws {
    npubHash = LocalDataCrypto.shared.digestHex(npub)
    encryptedNPub = try LocalDataCrypto.shared.encryptString(npub, ownerPubkey: ownerPubkey) ?? ""
    encryptedDisplayName =
      try LocalDataCrypto.shared.encryptString(displayName, ownerPubkey: ownerPubkey) ?? ""
  }

  func matchesNPub(_ npub: String) -> Bool {
    npubHash == LocalDataCrypto.shared.digestHex(npub)
  }
}
