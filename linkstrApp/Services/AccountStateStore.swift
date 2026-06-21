import Foundation
import SwiftData

struct ProfileMetadataSnapshot {
  let chosenName: String?
  let content: String?
  let createdAt: Date?
  let eventID: String?
}

@MainActor
final class AccountStateStore {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func followListWatermark(ownerPubkey: String) throws -> (createdAt: Date?, eventID: String?) {
    guard let state = try accountState(ownerPubkey: ownerPubkey) else {
      return (nil, nil)
    }
    return (
      state.followListUpdatedAt,
      NostrValueNormalizer.normalizedEventID(state.followListEventID)
    )
  }

  func setFollowListWatermark(ownerPubkey: String, createdAt: Date, eventID: String?) throws {
    let state = try ensureAccountState(ownerPubkey: ownerPubkey)
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)
    if state.followListUpdatedAt == createdAt && state.followListEventID == normalizedEventID {
      return
    }
    state.setFollowListWatermark(createdAt: createdAt, eventID: normalizedEventID)
    try modelContext.save()
  }

  func profileMetadata(ownerPubkey: String) throws -> ProfileMetadataSnapshot {
    guard let state = try accountState(ownerPubkey: ownerPubkey) else {
      return ProfileMetadataSnapshot(chosenName: nil, content: nil, createdAt: nil, eventID: nil)
    }
    return ProfileMetadataSnapshot(
      chosenName: state.nostrProfileName,
      content: state.profileMetadataContent,
      createdAt: state.profileMetadataUpdatedAt,
      eventID: NostrValueNormalizer.normalizedEventID(state.profileMetadataEventID)
    )
  }

  func setProfileMetadata(
    ownerPubkey: String,
    chosenName: String?,
    content: String?,
    createdAt: Date,
    eventID: String?
  ) throws {
    let state = try ensureAccountState(ownerPubkey: ownerPubkey)
    let normalizedName = NostrProfileMetadata.normalizedChosenName(chosenName)
    let normalizedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)

    if state.nostrProfileName == normalizedName,
      state.profileMetadataContent
        == (normalizedContent?.isEmpty == true ? nil : normalizedContent),
      state.profileMetadataUpdatedAt == createdAt,
      state.profileMetadataEventID == normalizedEventID {
      return
    }

    state.setProfileMetadata(
      chosenName: normalizedName,
      content: normalizedContent,
      createdAt: createdAt,
      eventID: normalizedEventID
    )
    try modelContext.save()
  }

  func deleteAccountState(ownerPubkey: String) throws {
    guard let state = try accountState(ownerPubkey: ownerPubkey) else { return }
    modelContext.delete(state)
    try modelContext.save()
  }

  private func accountState(ownerPubkey: String) throws -> AccountStateEntity? {
    let descriptor = FetchDescriptor<AccountStateEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    return try modelContext.fetch(descriptor).first
  }

  private func ensureAccountState(ownerPubkey: String) throws -> AccountStateEntity {
    if let existing = try accountState(ownerPubkey: ownerPubkey) {
      return existing
    }
    let state = AccountStateEntity(ownerPubkey: ownerPubkey)
    modelContext.insert(state)
    try modelContext.save()
    return state
  }
}
