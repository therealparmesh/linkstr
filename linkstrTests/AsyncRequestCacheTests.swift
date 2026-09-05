import XCTest

@testable import linkstr

final class AsyncRequestCacheTests: XCTestCase {
  func testConcurrentRequestsShareWorkAndCancelledCallerDoesNotCancelResult() async throws {
    let cache = AsyncRequestCache<String, Int>(maximumCachedValueCount: 2)
    let loader = ControlledAsyncLoader(value: 42)

    let cancelledRequest = Task {
      await cache.value(for: "same") { await loader.load() }
    }
    let startDeadline = Date(timeIntervalSinceNow: 1)
    while await loader.currentCallCount() == 0, Date() < startDeadline {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let initialCallCount = await loader.currentCallCount()
    XCTAssertEqual(initialCallCount, 1)

    let survivingRequest = Task {
      await cache.value(for: "same") { await loader.load() }
    }
    await Task.yield()
    cancelledRequest.cancel()
    await loader.finish()

    let cancelledValue = await cancelledRequest.value
    let survivingValue = await survivingRequest.value
    let cachedValue = await cache.value(for: "same") { await loader.load() }
    let callCount = await loader.currentCallCount()

    XCTAssertNil(cancelledValue)
    XCTAssertEqual(survivingValue, 42)
    XCTAssertEqual(cachedValue, 42)
    XCTAssertEqual(callCount, 1)
  }

  func testCachedValuesStayWithinConfiguredLimit() async {
    let cache = AsyncRequestCache<String, Int>(maximumCachedValueCount: 2)

    _ = await cache.value(for: "first") { 1 }
    _ = await cache.value(for: "second") { 2 }
    _ = await cache.value(for: "third") { 3 }
    let retainedValue = await cache.value(for: "second") { 20 }
    let reloadedValue = await cache.value(for: "first") { 4 }

    XCTAssertEqual(retainedValue, 2)
    XCTAssertEqual(reloadedValue, 4)
  }
}

private actor ControlledAsyncLoader {
  let value: Int
  private var callCount = 0
  private var isFinished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  init(value: Int) {
    self.value = value
  }

  func load() async -> Int {
    callCount += 1
    if !isFinished {
      await withCheckedContinuation { finishWaiters.append($0) }
    }
    return value
  }

  func finish() {
    isFinished = true
    finishWaiters.forEach { $0.resume() }
    finishWaiters.removeAll()
  }

  func currentCallCount() -> Int {
    callCount
  }
}
