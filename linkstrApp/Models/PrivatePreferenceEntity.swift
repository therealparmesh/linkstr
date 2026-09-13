import Foundation
import NostrSDK
import SwiftData

@Model
final class PrivatePreferenceEntity {
  @Attribute(.unique) var storageID: String
  var ownerPubkey: String
  var eventData: Data
  var needsPublish: Bool

  init(event: NostrEvent, identifier: String, needsPublish: Bool) throws {
    self.storageID = "\(event.pubkey):\(identifier)"
    self.ownerPubkey = event.pubkey
    self.eventData = try JSONEncoder().encode(event)
    self.needsPublish = needsPublish
  }

  func event() throws -> NostrEvent {
    try JSONDecoder().decode(NostrEvent.self, from: eventData)
  }
}
