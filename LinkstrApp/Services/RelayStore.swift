import Foundation
import SwiftData

@MainActor
final class RelayStore {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func ensureDefaultRelays() throws {
    let relays = try fetchRelays()
    guard relays.isEmpty else { return }
    RelayDefaults.urls.forEach { modelContext.insert(RelayEntity(url: $0)) }
    try modelContext.save()
  }

  func fetchRelays() throws -> [RelayEntity] {
    let descriptor = FetchDescriptor<RelayEntity>(sortBy: [SortDescriptor(\.createdAt)])
    return try modelContext.fetch(descriptor)
  }

  func addRelay(url: URL) throws {
    modelContext.insert(RelayEntity(url: url.absoluteString))
    try modelContext.save()
  }

  func removeRelay(_ relay: RelayEntity) throws {
    modelContext.delete(relay)
    try modelContext.save()
  }

  func toggleRelay(_ relay: RelayEntity) throws {
    relay.isEnabled.toggle()
    try modelContext.save()
  }

  func resetDefaultRelays() throws {
    let descriptor = FetchDescriptor<RelayEntity>()
    let existingRelays = try modelContext.fetch(descriptor)
    existingRelays.forEach(modelContext.delete)

    RelayDefaults.urls.forEach { modelContext.insert(RelayEntity(url: $0)) }
    try modelContext.save()
  }

  @discardableResult
  func updateRelayStatus(relayURL: String, status: RelayHealthStatus, message: String?) throws
    -> Bool
  {
    let descriptor = FetchDescriptor<RelayEntity>(predicate: #Predicate { $0.url == relayURL })
    guard let relay = try modelContext.fetch(descriptor).first else { return false }

    let normalizedMessage: String?
    if let message {
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      normalizedMessage = trimmed.isEmpty ? nil : trimmed
    } else {
      normalizedMessage = nil
    }

    // Relay status is transient runtime state. Persisting every update is expensive and can block
    // scene transitions under high reconnect churn.
    if relay.status == status && relay.lastError == normalizedMessage {
      return false
    }

    relay.status = status
    relay.lastError = normalizedMessage
    return true
  }
}
