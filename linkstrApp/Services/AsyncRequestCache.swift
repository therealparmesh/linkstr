enum CacheLimits {
  static let maximumEntryCount = 200
}

actor AsyncRequestCache<Key: Hashable & Sendable, Value: Sendable> {
  private let maximumCachedValueCount: Int
  private let shouldCache: @Sendable (Value) -> Bool
  private var cachedValues: [Key: Value] = [:]
  private var cachedValueOrder: [Key] = []
  private var inFlightRequests: [Key: Task<Value?, Never>] = [:]

  init(
    maximumCachedValueCount: Int = 0,
    shouldCache: @escaping @Sendable (Value) -> Bool = { _ in true }
  ) {
    self.maximumCachedValueCount = max(0, maximumCachedValueCount)
    self.shouldCache = shouldCache
  }

  func value(
    for key: Key,
    load: @escaping @Sendable () async -> Value?
  ) async -> Value? {
    guard !Task.isCancelled else { return nil }

    if let cachedValue = cachedValues[key] {
      return cachedValue
    }

    if let request = inFlightRequests[key] {
      let value = await request.value
      return Task.isCancelled ? nil : value
    }

    let request = Task { await load() }
    inFlightRequests[key] = request
    let value = await request.value
    inFlightRequests[key] = nil

    if let value, maximumCachedValueCount > 0, shouldCache(value) {
      cache(value, for: key)
    }

    return Task.isCancelled ? nil : value
  }

  func invalidate(_ key: Key) {
    cachedValues.removeValue(forKey: key)
    cachedValueOrder.removeAll { $0 == key }
  }

  private func cache(_ value: Value, for key: Key) {
    cachedValues[key] = value
    cachedValueOrder.append(key)

    if cachedValues.count > maximumCachedValueCount {
      cachedValues.removeValue(forKey: cachedValueOrder.removeFirst())
    }
  }
}
