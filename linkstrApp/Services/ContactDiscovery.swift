import Foundation
import NostrSDK
import SwiftData

@MainActor
final class ContactDiscovery: ObservableObject, EventVerifying {
  struct Query {
    let authors: Set<String>?
    let expectedRelays: Set<String>
    var completedRelays = Set<String>()
    var failed = false
    var events = Set<String>()
    var oldestTimestamp: Int?
    let limit: Int
  }

  @Published var loadState: ContactListLoadState = .loading
  var isLoading: Bool { loadState == .loading }
  var queryFailed = false
  @Published var canLoadMore = false
  let context: ModelContext
  var pool: RelayPool?
  var owner: String?
  var isVisible = false
  var queries: [String: Query] = [:]
  var timeouts: [String: Task<Void, Never>] = [:]
  var pendingAuthors = Set<String>()
  var verifiedAuthors = Set<String>()
  var visibleAuthors = Set<String>()
  var liveUpdateTask: Task<Void, Never>?
  var liveSubscriptionID: String?
  var discoverySubscriptionID: String?
  var discoveryLiveSubscriptionID: String?
  var cursor: Int?
  var pageLimit = 200

  init(modelContext: ModelContext) { context = modelContext }

  func show(ownerPubkey: String) {
    if let owner, owner != ownerPubkey { reset() }
    owner = ownerPubkey
    isVisible = true
    refresh()
  }

  func hide() {
    isVisible = false
    closeSubscriptions()
    visibleAuthors.removeAll()
  }

  func connect(_ pool: RelayPool) {
    self.pool = pool
    if isVisible { refresh() }
  }

  func disconnect() {
    closeSubscriptions()
    pool = nil
  }

  func reset() {
    hide()
    owner = nil
  }

  func refresh() {
    closeSubscriptions()
    guard isVisible, let owner else { return }
    cursor = nil
    pageLimit = 200
    canLoadMore = false
    verifiedAuthors.removeAll()
    queryFailed = false
    do {
      pendingAuthors = Set(
        try records(ownerPubkey: owner).filter(\.followsOwner).map(\.followerPubkey))
    } catch {
      return
    }
    guard !connectedRelays.isEmpty else {
      return
    }
    if let filter = Filter(kinds: [3], pubkeys: [owner], limit: 0) {
      let id = "linkstr-contact-new-\(UUID().uuidString.lowercased())"
      discoveryLiveSubscriptionID = id
      _ = pool?.subscribe(with: filter, subscriptionId: id)
    }
    beginDiscoveryPage()
    startAuthorQueries()
    updateLiveSubscription()
  }

  func loadMore() {
    guard canLoadMore, !isLoading else { return }
    queryFailed = false
    beginDiscoveryPage()
  }

  func records(ownerPubkey: String) throws -> [FollowRelationshipEntity] {
    try context.fetch(
      FetchDescriptor<FollowRelationshipEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == ownerPubkey
        }))
  }

  func clear(ownerPubkey: String) throws {
    if owner == ownerPubkey { reset() }
    for record in try records(ownerPubkey: ownerPubkey) { context.delete(record) }
    try context.save()
  }

  func persist(_ incoming: ReceivedFollowList, ownerPubkey: String) throws {
    guard incoming.authorPubkey != ownerPubkey,
      NostrValueNormalizer.normalizedPubkeyHex(incoming.authorPubkey) != nil
    else { return }
    let storageID = "\(ownerPubkey):\(incoming.authorPubkey)"
    let record = try context.fetch(
      FetchDescriptor<FollowRelationshipEntity>(
        predicate: #Predicate {
          $0.storageID == storageID
        })
    ).first
    if let record {
      guard
        NostrValueNormalizer.shouldApplyReplaceableEvent(
          currentUpdatedAt: record.updatedAt, currentEventID: record.eventID,
          incomingUpdatedAt: incoming.createdAt, incomingEventID: incoming.eventID
        )
      else { return }
      let previous = (record.followsOwner, record.updatedAt, record.eventID)
      record.followsOwner = incoming.followedPubkeys.contains(ownerPubkey)
      record.updatedAt = incoming.createdAt
      record.eventID = incoming.eventID
      do { try context.save() } catch {
        (record.followsOwner, record.updatedAt, record.eventID) = previous
        throw error
      }
    } else {
      let record = FollowRelationshipEntity(ownerPubkey: ownerPubkey, incoming: incoming)
      context.insert(record)
      do { try context.save() } catch {
        context.delete(record)
        throw error
      }
    }
  }

  var connectedRelays: Set<String> {
    Set(
      pool?.relays.compactMap { relay in
        if case .connected = relay.state { return relay.url.absoluteString }
        return nil
      } ?? [])
  }

  func closeSubscriptions() {
    for id in queries.keys { pool?.closeSubscription(with: id) }
    if let liveSubscriptionID { pool?.closeSubscription(with: liveSubscriptionID) }
    if let discoveryLiveSubscriptionID {
      pool?.closeSubscription(with: discoveryLiveSubscriptionID)
    }
    timeouts.values.forEach { $0.cancel() }
    timeouts.removeAll()
    queries.removeAll()
    pendingAuthors.removeAll()
    liveUpdateTask?.cancel()
    liveUpdateTask = nil
    discoverySubscriptionID = nil
    discoveryLiveSubscriptionID = nil
    liveSubscriptionID = nil
    loadState = .unavailable
  }
}
