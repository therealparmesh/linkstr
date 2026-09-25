import NostrSDK
import XCTest

@testable import linkstr

@MainActor
final class ContactLoadingTests: XCTestCase {
  func testFollowListWaitsForAllRelaysAndIgnoresObsoleteOrDuplicateResponses() {
    let service = NostrDMService()
    defer { service.stop() }
    service.beginFollowListQuery(relayURLs: ["first", "second"])
    let originalID = service.followListSubscriptionID
    service.completeFollowListQuery(relayURL: "unknown", subscriptionID: originalID)
    service.completeFollowListQuery(relayURL: "first", subscriptionID: "obsolete")
    service.completeFollowListQuery(relayURL: "first", subscriptionID: originalID)
    service.completeFollowListQuery(relayURL: "first", subscriptionID: originalID, failed: true)
    XCTAssertEqual(service.contactListLoadState, .loading)
    service.completeFollowListQuery(relayURL: "second", subscriptionID: originalID)
    XCTAssertEqual(service.contactListLoadState, .ready)
    XCTAssertNil(service.followListTimeoutTask)

    service.beginFollowListQuery(relayURLs: ["first"])
    XCTAssertNotEqual(service.followListSubscriptionID, originalID)
    service.completeFollowListQuery(relayURL: "first", subscriptionID: originalID)
    XCTAssertEqual(service.contactListLoadState, .loading)
    service.completeFollowListQuery(relayURL: "first", subscriptionID: service.followListSubscriptionID)
    XCTAssertEqual(service.contactListLoadState, .ready)
  }

  func testRetryDeliversTheSameSignedFollowListAgainWithoutRestartingMessages() throws {
    let service = NostrDMService()
    defer { service.stop() }
    let keypair = try XCTUnwrap(Keypair())
    service.keypair = keypair
    let event = try service.followList(withPubkeys: [], signedBy: keypair)
    var received = 0
    service.onFollowList = { _ in received += 1 }
    service.processedEventIDs = ["message"]
    service.beginFollowListQuery(relayURLs: ["relay"])
    service.handleIncomingEvent(event, subscriptionID: service.followListSubscriptionID)
    service.handleIncomingEvent(event, subscriptionID: service.followListSubscriptionID)
    XCTAssertEqual(received, 1)
    service.beginFollowListQuery(relayURLs: ["relay"])
    service.handleIncomingEvent(event, subscriptionID: service.followListSubscriptionID)
    XCTAssertEqual(received, 2)
    XCTAssertEqual(service.processedEventIDs, ["message"])
  }

}
