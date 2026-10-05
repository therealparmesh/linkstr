import Foundation

/// An inclusive cursor belongs to one relay and one filter, never to a combined pool response.
struct RelayHistoryPage {
  var until: Int?
  var limit: Int
  let baseLimit: Int
  let maximumLimit: Int
  private(set) var eventIDs = Set<String>()
  private(set) var oldest: Int?
  var invalidResponse = false

  init(until: Int? = nil, limit: Int = 500, maximumLimit: Int = 4_000) {
    self.until = until
    self.limit = limit
    self.baseLimit = limit
    self.maximumLimit = maximumLimit
  }

  mutating func record(id: String, timestamp: Int) {
    guard !eventIDs.contains(id) else { return }
    guard timestamp >= 0, until.map({ timestamp <= $0 }) != false, eventIDs.count < maximumLimit else {
      invalidResponse = true
      return
    }
    eventIDs.insert(id)
    oldest = min(oldest ?? timestamp, timestamp)
  }

  enum Completion {
    case next(RelayHistoryPage)
    case finished
    case incomplete
  }

  func completion() -> Completion {
    guard !invalidResponse else { return .incomplete }
    guard let oldest else { return .finished }
    var next = self
    next.eventIDs = []
    next.oldest = nil
    if oldest == until {
      if eventIDs.count >= limit {
        guard limit < maximumLimit else { return .incomplete }
        next.limit = min(limit * 2, maximumLimit)
      } else {
        // The inclusive boundary was exhausted; probe the older range even after a short page.
        guard oldest > 0 else { return .finished }
        next.until = oldest - 1
        next.limit = baseLimit
      }
    } else {
      next.until = oldest
      next.limit = baseLimit
    }
    return .next(next)
  }
}
