import Foundation

struct ContactSnapshot: Codable, Identifiable, Hashable {
  let id: String
  let npub: String
  var displayName: String

  init(id: String = UUID().uuidString, npub: String, displayName: String) {
    self.id = id
    self.npub = npub
    self.displayName = displayName
  }
}
