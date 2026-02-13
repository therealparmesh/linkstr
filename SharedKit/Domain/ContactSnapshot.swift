import Foundation

struct ContactSnapshot: Codable, Identifiable, Hashable {
  let id: String
  let ownerPubkey: String
  let npub: String
  var displayName: String

  init(
    id: String = UUID().uuidString,
    ownerPubkey: String,
    npub: String,
    displayName: String
  ) {
    self.id = id
    self.ownerPubkey = ownerPubkey
    self.npub = npub
    self.displayName = displayName
  }
}
