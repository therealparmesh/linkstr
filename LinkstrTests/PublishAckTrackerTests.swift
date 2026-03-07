import XCTest

@testable import Linkstr

final class PublishAckTrackerTests: XCTestCase {
  func testBatchSucceedsOnlyAfterEveryEventIsAcknowledged() {
    var tracker = PublishAckTracker()
    let batchID = tracker.registerBatch(
      eventIDs: ["event-a", "event-b"],
      expectedRelayURLs: ["wss://relay-a.example.com", "wss://relay-b.example.com"]
    )

    XCTAssertNil(
      tracker.acknowledge(
        relayURL: "wss://relay-a.example.com",
        eventID: "event-a",
        success: true,
        message: "ok"
      )
    )

    let completion = tracker.acknowledge(
      relayURL: "wss://relay-b.example.com",
      eventID: "event-b",
      success: true,
      message: "ok"
    )

    XCTAssertEqual(
      completion,
      PublishAckCompletion(batchID: batchID, outcome: .succeeded)
    )
  }

  func testBatchFailsWhenAnyEventIsRejectedByAllExpectedRelays() {
    var tracker = PublishAckTracker()
    let batchID = tracker.registerBatch(
      eventIDs: ["event-a", "event-b"],
      expectedRelayURLs: ["wss://relay-a.example.com", "wss://relay-b.example.com"]
    )

    XCTAssertNil(
      tracker.acknowledge(
        relayURL: "wss://relay-a.example.com",
        eventID: "event-b",
        success: false,
        message: "blocked"
      )
    )

    let completion = tracker.acknowledge(
      relayURL: "wss://relay-b.example.com",
      eventID: "event-b",
      success: false,
      message: "blocked"
    )

    XCTAssertEqual(
      completion,
      PublishAckCompletion(batchID: batchID, outcome: .failed("blocked"))
    )
    XCTAssertNil(
      tracker.acknowledge(
        relayURL: "wss://relay-a.example.com",
        eventID: "event-a",
        success: true,
        message: "ok"
      )
    )
  }

  func testPruneRelayFailsBatchWhenNoRelayPathsRemain() {
    var tracker = PublishAckTracker()
    let batchID = tracker.registerBatch(
      eventIDs: ["event-a"],
      expectedRelayURLs: ["wss://relay-a.example.com"]
    )

    XCTAssertEqual(
      tracker.pruneRelay("wss://relay-a.example.com"),
      [PublishAckCompletion(batchID: batchID, outcome: .failed("relay connection dropped."))]
    )
  }
}
