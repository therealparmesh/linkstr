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
    let relayURL = canonicalRelayURLString(from: url)
    let existingRelayURLs = try fetchRelays().map(\.url)
    if existingRelayURLs.contains(where: { canonicalRelayURLString(from: $0) == relayURL }) {
      throw RelayStoreError.duplicateRelay
    }

    modelContext.insert(RelayEntity(url: relayURL))
    try modelContext.save()
  }

  func removeRelay(_ relay: RelayEntity) throws {
    modelContext.delete(relay)
    try modelContext.save()
  }

  func toggleRelay(_ relay: RelayEntity) throws {
    relay.isEnabled.toggle()
    if relay.isEnabled == false {
      relay.status = .disconnected
      relay.lastError = nil
    }
    try modelContext.save()
  }

  func resetDefaultRelays() throws {
    let descriptor = FetchDescriptor<RelayEntity>()
    let existingRelays = try modelContext.fetch(descriptor)
    existingRelays.forEach(modelContext.delete)

    RelayDefaults.urls.forEach { modelContext.insert(RelayEntity(url: $0)) }
    try modelContext.save()
  }

  private func canonicalRelayURLString(from url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    components.fragment = nil
    if components.path == "/" {
      components.path = ""
    }
    return components.url?.absoluteString ?? url.absoluteString
  }

  private func canonicalRelayURLString(from rawValue: String) -> String {
    guard let url = URL(string: rawValue) else { return rawValue.lowercased() }
    return canonicalRelayURLString(from: url)
  }
}

private enum RelayStoreError: LocalizedError {
  case duplicateRelay

  var errorDescription: String? {
    switch self {
    case .duplicateRelay:
      return "That relay is already in your list."
    }
  }
}
