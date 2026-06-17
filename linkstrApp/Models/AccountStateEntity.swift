import Foundation
import SwiftData

@Model
final class AccountStateEntity {
  @Attribute(.unique) var ownerPubkey: String
  var followListUpdatedAt: Date?
  var followListEventID: String?
  var nostrProfileName: String?
  var profileMetadataContent: String?
  var profileMetadataUpdatedAt: Date?
  var profileMetadataEventID: String?
  var createdAt: Date
  var updatedAt: Date

  init(
    ownerPubkey: String,
    followListUpdatedAt: Date? = nil,
    followListEventID: String? = nil,
    nostrProfileName: String? = nil,
    profileMetadataContent: String? = nil,
    profileMetadataUpdatedAt: Date? = nil,
    profileMetadataEventID: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.ownerPubkey = ownerPubkey
    self.followListUpdatedAt = followListUpdatedAt
    self.followListEventID = NostrValueNormalizer.normalizedEventID(followListEventID)
    self.nostrProfileName = NostrProfileMetadata.normalizedChosenName(nostrProfileName)
    self.profileMetadataContent = Self.normalizedMetadataContent(profileMetadataContent)
    self.profileMetadataUpdatedAt = profileMetadataUpdatedAt
    self.profileMetadataEventID = NostrValueNormalizer.normalizedEventID(profileMetadataEventID)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  func setFollowListWatermark(createdAt: Date, eventID: String?) {
    followListUpdatedAt = createdAt
    followListEventID = NostrValueNormalizer.normalizedEventID(eventID)
    updatedAt = .now
  }

  func setProfileMetadata(
    chosenName: String?,
    content: String?,
    createdAt: Date,
    eventID: String?
  ) {
    nostrProfileName = NostrProfileMetadata.normalizedChosenName(chosenName)
    profileMetadataContent = Self.normalizedMetadataContent(content)
    profileMetadataUpdatedAt = createdAt
    profileMetadataEventID = NostrValueNormalizer.normalizedEventID(eventID)
    updatedAt = .now
  }

  private static func normalizedMetadataContent(_ content: String?) -> String? {
    let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}
