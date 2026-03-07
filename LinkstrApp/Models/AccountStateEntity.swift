import Foundation
import SwiftData

@Model
final class AccountStateEntity {
  @Attribute(.unique) var ownerPubkey: String
  var followListUpdatedAt: Date?
  var followListEventID: String?
  var createdAt: Date
  var updatedAt: Date

  init(
    ownerPubkey: String,
    followListUpdatedAt: Date? = nil,
    followListEventID: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.ownerPubkey = ownerPubkey
    self.followListUpdatedAt = followListUpdatedAt
    self.followListEventID = NostrValueNormalizer.normalizedEventID(followListEventID)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  func setFollowListWatermark(createdAt: Date, eventID: String?) {
    followListUpdatedAt = createdAt
    followListEventID = NostrValueNormalizer.normalizedEventID(eventID)
    updatedAt = .now
  }
}
