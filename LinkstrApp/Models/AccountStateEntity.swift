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
    self.followListEventID = Self.normalizedEventIDToken(followListEventID)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  func setFollowListWatermark(createdAt: Date, eventID: String?) {
    followListUpdatedAt = createdAt
    followListEventID = Self.normalizedEventIDToken(eventID)
    updatedAt = .now
  }

  static func normalizedEventIDToken(_ eventID: String?) -> String? {
    guard let eventID else { return nil }
    let trimmed = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
