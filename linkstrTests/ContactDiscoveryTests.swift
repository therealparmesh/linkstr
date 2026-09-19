import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class ContactDiscoveryTests: XCTestCase {
  private var container: ModelContainer?

  func testSignedFollowUnfollowAndStaleReplayRemainAccountScoped() throws {
    let discovery = try makeDiscovery()
    let owner = try TestKeyMaterialFactory.makePubkeyHex()
    let otherOwner = try TestKeyMaterialFactory.makePubkeyHex()
    let author = try XCTUnwrap(Keypair())
    discovery.owner = owner
    discovery.isVisible = true
    discovery.discoveryLiveSubscriptionID = "discovery"
    discovery.liveSubscriptionID = "author"
    discovery.visibleAuthors = [author.publicKey.hex]
    let follow = try event(author: author, keys: [owner], timestamp: 100)
    discovery.receive(follow, subscriptionID: "discovery", relayURL: "relay")
    XCTAssertEqual(try discovery.records(ownerPubkey: owner).map(\.followsOwner), [true])

    let unfollow = try event(author: author, keys: [], timestamp: 101)
    discovery.receive(unfollow, subscriptionID: "author", relayURL: "relay")
    discovery.receive(follow, subscriptionID: "discovery", relayURL: "relay")
    let restarted = ContactDiscovery(modelContext: discovery.context)
    try restarted.persist(
      ReceivedFollowList(
        eventID: follow.id, authorPubkey: author.publicKey.hex,
        followedPubkeys: [owner], createdAt: follow.createdDate
      ), ownerPubkey: owner)
    XCTAssertEqual(try restarted.records(ownerPubkey: owner).map(\.followsOwner), [false])
    try restarted.persist(
      ReceivedFollowList(
        eventID: follow.id, authorPubkey: author.publicKey.hex,
        followedPubkeys: [otherOwner], createdAt: follow.createdDate
      ), ownerPubkey: otherOwner)
    try restarted.clear(ownerPubkey: owner)
    XCTAssertEqual(try restarted.records(ownerPubkey: otherOwner).map(\.followsOwner), [true])
  }

  func testInvalidOrObsoleteSubscriptionCannotCreateRelationships() throws {
    let discovery = try makeDiscovery()
    let owner = try TestKeyMaterialFactory.makePubkeyHex()
    let author = try XCTUnwrap(Keypair())
    discovery.owner = owner
    discovery.isVisible = true
    discovery.discoveryLiveSubscriptionID = "live"
    let valid = try event(author: author, keys: [owner], timestamp: 100)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    object["sig"] = String(repeating: "0", count: 128)
    let invalid = try JSONDecoder().decode(
      NostrEvent.self, from: JSONSerialization.data(withJSONObject: object))
    discovery.receive(invalid, subscriptionID: "live", relayURL: "relay")
    discovery.receive(valid, subscriptionID: "obsolete", relayURL: "relay")
    discovery.hide()
    discovery.receive(valid, subscriptionID: "live", relayURL: "relay")
    XCTAssertTrue(try discovery.records(ownerPubkey: owner).isEmpty)
  }

  func testEqualTimeFollowListsConvergeToLowestIDInEitherOrder() throws {
    let discovery = try makeDiscovery()
    let owner = try TestKeyMaterialFactory.makePubkeyHex()
    let author = try XCTUnwrap(Keypair())
    let events = try [
      event(author: author, keys: [owner], timestamp: 100),
      event(author: author, keys: [], timestamp: 100)
    ].sorted { $0.id < $1.id }
    for order in [events, events.reversed().map { $0 }] {
      try discovery.clear(ownerPubkey: owner)
      for event in order {
        try discovery.persist(
          ReceivedFollowList(
            eventID: event.id, authorPubkey: event.pubkey,
            followedPubkeys: event.referencedPubkeys, createdAt: event.createdDate
          ), ownerPubkey: owner)
      }
      XCTAssertEqual(
        try discovery.records(ownerPubkey: owner).first?.eventID, events[0].id)
    }
  }

  func testFullTimestampPageNeverSkipsTheBoundaryAndReportsItsLimit() throws {
    let discovery = try makeDiscovery()
    for limit in [200, 200, 400, 800, 1_600] {
      discovery.queries["page"] = ContactDiscovery.Query(
        authors: nil, expectedRelays: ["relay"], events: Set((0..<limit).map(String.init)),
        oldestTimestamp: 100, limit: limit
      )
      discovery.finishQuery("page")
      XCTAssertEqual(discovery.cursor, 100)
    }
    XCTAssertFalse(discovery.canLoadMore)
    XCTAssertTrue(discovery.hadPartialResults)
  }

  func testQueryIgnoresUnexpectedRelaysAndDoesNotTreatDuplicatesAsOverflow() throws {
    let discovery = try makeDiscovery()
    let owner = try TestKeyMaterialFactory.makePubkeyHex()
    let follow = try event(author: XCTUnwrap(Keypair()), keys: [owner], timestamp: 100)
    discovery.owner = owner
    discovery.isVisible = true
    discovery.discoverySubscriptionID = "page"
    discovery.queries["page"] = ContactDiscovery.Query(
      authors: nil, expectedRelays: ["expected"], limit: 1)

    discovery.receive(follow, subscriptionID: "page", relayURL: "unexpected")
    XCTAssertTrue(try discovery.records(ownerPubkey: owner).isEmpty)
    discovery.receive(follow, subscriptionID: "page", relayURL: "expected")
    discovery.receive(follow, subscriptionID: "page", relayURL: "expected")
    XCTAssertEqual(try discovery.records(ownerPubkey: owner).count, 1)
    XCTAssertEqual(discovery.queries["page"]?.events.count, 1)
    XCTAssertFalse(discovery.hadPartialResults)
  }

  private func makeDiscovery() throws -> ContactDiscovery {
    let schema = Schema([FollowRelationshipEntity.self])
    let container = try ModelContainer(
      for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    self.container = container
    return ContactDiscovery(modelContext: container.mainContext)
  }

  private func event(author: Keypair, keys: [String], timestamp: Int64) throws -> NostrEvent {
    try NostrEvent.Builder<NostrEvent>(kind: .followList).createdAt(timestamp)
      .appendTags(contentsOf: keys.map { try PubkeyTag(pubkey: $0).tag }).build(signedBy: author)
  }
}
