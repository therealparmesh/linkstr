import Foundation
import NostrSDK

extension ContactDiscovery {
  func beginDiscoveryPage() {
    guard let owner,
      let filter = Filter(kinds: [3], pubkeys: [owner], until: cursor, limit: pageLimit)
    else { return }
    if let discoverySubscriptionID { pool?.closeSubscription(with: discoverySubscriptionID) }
    discoverySubscriptionID = beginQuery(filter: filter, authors: nil, limit: pageLimit)
  }

  func beginQuery(filter: Filter, authors: Set<String>?, limit: Int) -> String? {
    let relays = connectedRelays
    guard let pool, !relays.isEmpty else {
      loadState = .unavailable
      return nil
    }
    let id = "linkstr-contacts-\(UUID().uuidString.lowercased())"
    queries[id] = Query(authors: authors, expectedRelays: relays, limit: limit)
    loadState = .loading
    _ = pool.subscribe(with: filter, subscriptionId: id)
    timeouts[id] = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
      self?.finishQuery(id, failed: true)
    }
    return id
  }

  func startAuthorQueries() {
    guard !connectedRelays.isEmpty else { return }
    while queries.values.filter({ $0.authors != nil }).count < 2, !pendingAuthors.isEmpty {
      let authors = Set(pendingAuthors.sorted().prefix(50))
      pendingAuthors.subtract(authors)
      guard let filter = Filter(authors: authors.sorted(), kinds: [3], limit: authors.count * 2)
      else { return }
      _ = beginQuery(filter: filter, authors: authors, limit: authors.count * 2)
    }
  }

  func receive(_ event: NostrEvent, subscriptionID: String, relayURL: String) async {
    guard await eventDecoder.isValid(event), !Task.isCancelled else { return }
    guard isVisible, let owner, event.kind == .followList, event.pubkey != owner else { return }
    let isDiscovery =
      subscriptionID == discoverySubscriptionID || subscriptionID == discoveryLiveSubscriptionID
    let isLive = subscriptionID == liveSubscriptionID && visibleAuthors.contains(event.pubkey)
    let query = queries[subscriptionID]
    guard isDiscovery || isLive || query?.authors?.contains(event.pubkey) == true else { return }
    guard !isDiscovery || event.referencedPubkeys.contains(owner) else { return }
    if var query {
      guard query.expectedRelays.contains(relayURL) else { return }
      // Count valid events even when their saved state is unchanged, so pagination can advance.
      guard query.events.contains(event.id)
        || query.events.count < query.limit * max(1, query.expectedRelays.count) else {
        return
      }
      query.events.insert(event.id)
      query.oldestTimestamp = min(
        query.oldestTimestamp ?? Int(event.createdAt), Int(event.createdAt))
      queries[subscriptionID] = query
    }
    do {
      try persist(
        ReceivedFollowList(
          eventID: event.id, authorPubkey: event.pubkey,
          followedPubkeys: event.referencedPubkeys, createdAt: event.createdDate
        ), ownerPubkey: owner)
    } catch {
      queryFailed = true
      if !isLoading { loadState = .unavailable }
    }
    if isDiscovery, !verifiedAuthors.contains(event.pubkey),
      !queries.values.contains(where: { $0.authors?.contains(event.pubkey) == true }) {
      pendingAuthors.insert(event.pubkey)
      startAuthorQueries()
    }
  }

  func complete(relayURL: String, subscriptionID: String, failed: Bool = false) {
    guard var query = queries[subscriptionID], query.expectedRelays.contains(relayURL),
      !query.completedRelays.contains(relayURL) else {
      return
    }
    query.failed = query.failed || failed
    query.completedRelays.insert(relayURL)
    queries[subscriptionID] = query
    if query.completedRelays.isSuperset(of: query.expectedRelays) { finishQuery(subscriptionID) }
  }

  func relayDisconnected(_ relayURL: String) {
    for id in Array(queries.keys) { complete(relayURL: relayURL, subscriptionID: id, failed: true) }
  }

  func finishQuery(_ id: String, failed: Bool = false) {
    guard let query = queries.removeValue(forKey: id) else { return }
    let failed = failed || query.failed
    queryFailed = queryFailed || failed
    timeouts.removeValue(forKey: id)?.cancel()
    if let authors = query.authors {
      pool?.closeSubscription(with: id)
      if !failed { verifiedAuthors.formUnion(authors) }
    } else {
      canLoadMore = !failed && query.events.count >= query.limit
      if canLoadMore, let oldest = query.oldestTimestamp {
        if cursor == oldest {
          if pageLimit < 1_600 {
            pageLimit *= 2
          } else {
            canLoadMore = false
            queryFailed = true
          }
        } else {
          cursor = oldest
          pageLimit = 200
        }
      }
      pool?.closeSubscription(with: id)
      discoverySubscriptionID = nil
    }
    startAuthorQueries()
    loadState = queries.isEmpty ? (queryFailed ? .unavailable : .ready) : .loading
  }

  func watch(_ pubkey: String, visible: Bool) {
    if visible { visibleAuthors.insert(pubkey) } else { visibleAuthors.remove(pubkey) }
    liveUpdateTask?.cancel()
    liveUpdateTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
      self?.updateLiveSubscription()
    }
  }

  func updateLiveSubscription() {
    if let liveSubscriptionID { pool?.closeSubscription(with: liveSubscriptionID) }
    liveSubscriptionID = nil
    guard isVisible, !visibleAuthors.isEmpty, !connectedRelays.isEmpty,
      let filter = Filter(
        authors: visibleAuthors.sorted(), kinds: [3], limit: visibleAuthors.count * 2)
    else { return }
    let id = "linkstr-contact-live-\(UUID().uuidString.lowercased())"
    liveSubscriptionID = id
    _ = pool?.subscribe(with: filter, subscriptionId: id)
  }
}
