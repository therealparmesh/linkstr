import NostrSDK
import XCTest

@testable import linkstr

@MainActor
final class NostrRelayDeliveryTests: XCTestCase {
  func testHistoryStaysOrderedWithoutDelayingSendAcknowledgments() async throws {
    let service = NostrDMService()
    let owner = try XCTUnwrap(Keypair())
    service.keypair = owner
    let relay = try Relay(url: XCTUnwrap(URL(string: "ws://127.0.0.1:1")))
    service.relayPool = RelayPool(relays: [relay])
    defer { service.stop() }
    let subscriptionID = "linkstr-backfill-order"
    service.completedBackfillKinds = [.author]
    service.activeBackfillStates[subscriptionID] = NostrDMService.BackfillState(
      kind: .recipient, page: 0, until: nil, pageSize: 500,
      expectedRelayURLs: [relay.url.absoluteString])
    let receiver = service.makeRelayReceiver()
    var delivered: [Int64] = []
    var completed: [[Int64]] = []
    var acknowledgedAt: Int?
    let acknowledgment = try JSONDecoder().decode(
      RelayResponse.self, from: Data(#"["OK","send",false,"restricted: read only"]"#.utf8))
    service.onRelayStatus = { _, status, _ in
      if status == .readOnly { acknowledgedAt = delivered.count }
    }
    service.onIncoming = {
      delivered.append($0.payload.timestamp)
      if delivered.count == 1 { receiver.relay(relay, didReceive: acknowledgment) }
    }
    service.onInitialBackfillComplete = {
      completed.append(delivered)
      receiver.finish()
    }
    for timestamp in 1...64 {
      let wrap = try wrappedPost(timestamp: Int64(timestamp), owner: owner, service: service)
      receiver.relay(relay, didReceive: RelayResponse.event(subscriptionId: subscriptionID, event: wrap))
    }
    receiver.relay(relay, didReceive: RelayResponse.eose(subscriptionId: subscriptionID))
    service.startReceiving(from: receiver)
    await service.receiveTask?.value
    XCTAssertEqual(delivered, Array(1...64).map(Int64.init))
    XCTAssertEqual(completed, [delivered])
    XCTAssertLessThan(try XCTUnwrap(acknowledgedAt), delivered.count)
  }

  func testStoppingDiscardsQueuedEventsAndResumeRetainsOnlySameAccountHistory() async throws {
    let service = NostrDMService()
    let owner = try XCTUnwrap(Keypair())
    let other = try XCTUnwrap(Keypair())
    service.keypair = owner
    let relay = try Relay(url: XCTUnwrap(URL(string: "ws://127.0.0.1:1")))
    service.relayPool = RelayPool(relays: [relay])
    defer { service.stop() }
    let first = try wrappedPost(timestamp: 1, owner: owner, service: service)
    let second = try wrappedPost(timestamp: 2, owner: owner, service: service)
    let receiver = service.makeRelayReceiver()
    var delivered: [Int64] = []
    service.onIncoming = { message in
      delivered.append(message.payload.timestamp)
      service.stop(clearHistory: false)
    }
    for wrap in [first, second] {
      receiver.relay(relay, didReceive: RelayResponse.event(subscriptionId: "live", event: wrap))
    }
    service.startReceiving(from: receiver)
    let task = service.receiveTask
    await task?.value
    XCTAssertEqual(delivered, [1])

    service.start(keypair: owner, relayURLs: [], onIncoming: { delivered.append($0.payload.timestamp) },
                  onRelayStatus: { _, _, _ in })
    try await NostrEventTestSupport.deliver(first, to: service)
    try await NostrEventTestSupport.deliver(second, to: service)
    XCTAssertEqual(delivered, [1, 2])

    service.start(keypair: other, relayURLs: [], onIncoming: { _ in XCTFail("wrong account") },
                  onRelayStatus: { _, _, _ in })
    try await NostrEventTestSupport.deliver(first, to: service)
    service.start(keypair: owner, relayURLs: [], onIncoming: { delivered.append($0.payload.timestamp) },
                  onRelayStatus: { _, _, _ in })
    try await NostrEventTestSupport.deliver(first, to: service)
    XCTAssertEqual(delivered, [1, 2, 1])
  }

  private func wrappedPost(timestamp: Int64, owner: Keypair, service: NostrDMService) throws -> GiftWrapEvent {
    let payload = NostrEventTestSupport.payload(.root, members: [], timestamp: timestamp)
    let rumor = try NostrEventTestSupport.rumor(payload, author: owner.publicKey)
    return try service.giftWrap(withRumor: rumor, toRecipient: owner.publicKey, signedBy: owner)
  }
}
