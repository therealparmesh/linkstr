import Foundation
import SwiftData

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
      normalizedEventIDToken(state.followListEventID)
    )
  }

  func setFollowListWatermark(ownerPubkey: String, createdAt: Date, eventID: String?) throws {
    let state = try ensureAccountState(ownerPubkey: ownerPubkey)
    let normalizedEventID = normalizedEventIDToken(eventID)
    if state.followListUpdatedAt == createdAt && state.followListEventID == normalizedEventID {
      return
    }
    state.setFollowListWatermark(createdAt: createdAt, eventID: normalizedEventID)
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

  private func normalizedEventIDToken(_ eventID: String?) -> String? {
    guard let eventID else { return nil }
    let trimmed = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
