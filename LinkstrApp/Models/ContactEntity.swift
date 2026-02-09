import Foundation
import SwiftData

@Model
final class ContactEntity {
  var npub: String
  var displayName: String
  var createdAt: Date

  init(npub: String, displayName: String, createdAt: Date = .now) {
    self.npub = npub
    self.displayName = displayName
    self.createdAt = createdAt
  }
}
