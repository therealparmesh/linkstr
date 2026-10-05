import XCTest

@testable import linkstr

final class RelayHistoryPageTests: XCTestCase {
  func testShortRelayPagesAndDuplicateBoundaryEventsStillReachOlderHistory() throws {
    let timestamps = [20, 20, 20, 10, 5]
    var page = RelayHistoryPage(limit: 4, maximumLimit: 16)
    var seen = Set<String>()
    var finished = false
    for _ in 0..<20 {
      // This relay returns at most three events, below the requested limit.
      let matches = timestamps.indices.filter { timestamps[$0] <= (page.until ?? Int.max) }.prefix(3)
      for index in matches {
        seen.insert(String(index))
        for _ in 0..<2 { page.record(id: String(index), timestamp: timestamps[index]) }
      }
      switch page.completion() {
      case .next(let next): page = next
      case .finished: finished = true
      case .incomplete: XCTFail("obtainable history was abandoned")
      }
      if finished { break }
    }
    XCTAssertTrue(finished)
    XCTAssertEqual(seen, Set(timestamps.indices.map(String.init)))
  }

  func testSaturatedTimestampExpandsWithoutSkippingAndStopsAtBound() {
    var page = RelayHistoryPage(until: 100, limit: 2, maximumLimit: 8)
    for size in [2, 4, 8] {
      for index in 0..<size { page.record(id: String(index), timestamp: 100) }
      switch page.completion() {
      case .next(let next):
        XCTAssertEqual(next.until, 100)
        XCTAssertGreaterThan(next.limit, page.limit)
        page = next
      case .incomplete: XCTAssertEqual(size, 8)
      case .finished: XCTFail("saturated page was treated as complete")
      }
    }
  }
}
