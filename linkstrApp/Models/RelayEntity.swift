import Foundation
import SwiftData

enum RelayHealthStatus: String, Codable, CaseIterable {
  case connected
  case connecting
  case readOnly
  case failed
  case disconnected
}

@Model
final class RelayEntity {
  @Attribute(.unique) var url: String
  var isEnabled: Bool
  var statusRaw: String
  var lastError: String?
  var createdAt: Date

  init(
    url: String, isEnabled: Bool = true, status: RelayHealthStatus = .disconnected,
    lastError: String? = nil, createdAt: Date = .now
  ) {
    self.url = url
    self.isEnabled = isEnabled
    self.statusRaw = status.rawValue
    self.lastError = lastError
    self.createdAt = createdAt
  }
}
