import XCTest

@testable import linkstr

final class PublishAckTrackerTests: XCTestCase {
  func testExpectedRelayCanAcceptAfterRejectingWhileAnotherRelayIsPending() {
    var tracker = PublishAckTracker()
    let batch = tracker.registerBatch(eventIDs: ["event"], expectedRelayURLs: ["first", "second"])
    XCTAssertTrue(
      tracker.acknowledge(relayURL: "first", eventID: "event", success: false, message: "auth required").isEmpty)
    XCTAssertEqual(
      tracker.acknowledge(relayURL: "first", eventID: "event", success: true, message: "ok"),
      [PublishAckCompletion(batchID: batch, outcome: .succeeded)])
  }

  func testSharedAcknowledgementCompletesAllWaitersAfterAnotherBatchIsRemoved() {
    var tracker = PublishAckTracker()
    let removed = tracker.registerBatch(eventIDs: ["shared"], expectedRelayURLs: ["relay"])
    let retained = tracker.registerBatch(eventIDs: ["shared"], expectedRelayURLs: ["relay"])
    let alsoRetained = tracker.registerBatch(eventIDs: ["shared"], expectedRelayURLs: ["relay"])
    let multiEvent = tracker.registerBatch(eventIDs: ["shared", "other"], expectedRelayURLs: ["relay"])
    tracker.removeBatch(removed)

    let completions = tracker.acknowledge(relayURL: "relay", eventID: "shared", success: true, message: "ok")
    XCTAssertEqual(Set(completions.map(\.batchID)), Set([retained, alsoRetained]))
    XCTAssertEqual(completions.map(\.outcome), [.succeeded, .succeeded])
    XCTAssertEqual(
      tracker.acknowledge(relayURL: "relay", eventID: "other", success: true, message: "ok"),
      [PublishAckCompletion(batchID: multiEvent, outcome: .succeeded)])
  }

  func testUnexpectedRelayCannotCompletePublication() {
    var tracker = PublishAckTracker()
    let batch = tracker.registerBatch(eventIDs: ["event"], expectedRelayURLs: ["expected"])

    XCTAssertTrue(
      tracker.acknowledge(relayURL: "unexpected", eventID: "event", success: true, message: "ok").isEmpty)
    XCTAssertEqual(
      tracker.acknowledge(relayURL: "expected", eventID: "event", success: true, message: "ok"),
      [PublishAckCompletion(batchID: batch, outcome: .succeeded)])
  }

  func testBatchSucceedsOnlyAfterEveryEventIsAcknowledged() {
    var tracker = PublishAckTracker()
    let batchID = tracker.registerBatch(
      eventIDs: ["event-a", "event-b"],
      expectedRelayURLs: ["wss://relay-a.example.com", "wss://relay-b.example.com"]
    )

    XCTAssertTrue(
      tracker.acknowledge(
        relayURL: "wss://relay-a.example.com",
        eventID: "event-a",
        success: true,
        message: "ok"
      ).isEmpty
    )

    let completion = tracker.acknowledge(
      relayURL: "wss://relay-b.example.com",
      eventID: "event-b",
      success: true,
      message: "ok"
    )

    XCTAssertEqual(
      completion,
      [PublishAckCompletion(batchID: batchID, outcome: .succeeded)]
    )
  }

  func testBatchFailsWhenAnyEventIsRejectedByAllExpectedRelays() {
    var tracker = PublishAckTracker()
    let batchID = tracker.registerBatch(
      eventIDs: ["event-a", "event-b"],
      expectedRelayURLs: ["wss://relay-a.example.com", "wss://relay-b.example.com"]
    )

    XCTAssertTrue(
      tracker.acknowledge(
        relayURL: "wss://relay-a.example.com",
        eventID: "event-b",
        success: false,
        message: "blocked"
      ).isEmpty
    )

    let completion = tracker.acknowledge(
      relayURL: "wss://relay-b.example.com",
      eventID: "event-b",
      success: false,
      message: "blocked"
    )

    XCTAssertEqual(
      completion,
      [PublishAckCompletion(batchID: batchID, outcome: .failed("blocked"))]
    )
    XCTAssertTrue(
      tracker.acknowledge(
        relayURL: "wss://relay-a.example.com",
        eventID: "event-a",
        success: true,
        message: "ok"
      ).isEmpty
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
