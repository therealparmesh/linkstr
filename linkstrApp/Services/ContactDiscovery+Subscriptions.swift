import Foundation
import NostrSDK

extension ContactDiscovery {
  func beginDiscoveryPage() {
    guard let owner else { return }
    for (relayURL, page) in discoveryPages where connectedRelays.contains(relayURL) {
      guard let filter = Filter(kinds: [3], pubkeys: [owner], until: page.until, limit: page.limit) else { continue }
      _ = beginQuery(filter: filter, authors: nil, relayURL: relayURL, page: page)
    }
  }

  func beginQuery(
    filter: Filter, authors: Set<String>?, relayURL: String? = nil, page: RelayHistoryPage? = nil
  ) -> String? {
    let relays = relayURL.map { Set([$0]) } ?? connectedRelays
    guard let pool, !relays.isEmpty else {
      loadState = .unavailable
      return nil
    }
    let id = "linkstr-contacts-\(UUID().uuidString.lowercased())"
    queries[id] = Query(authors: authors, expectedRelays: relays, page: page)
    loadState = .loading
    for relay in pool.relays where relays.contains(relay.url.absoluteString) {
      do {
        try relay.subscribe(with: filter, subscriptionId: id)
      } catch {
        complete(relayURL: relay.url.absoluteString, subscriptionID: id, failed: true)
      }
    }
    if queries[id] != nil {
      timeouts[id] = Task { [weak self] in
        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
        guard let self else { return }
        if let receiver = self.receiver {
          receiver.contactDeadline(id)
        } else {
          self.finishQuery(id, failed: true)
        }
      }
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
      _ = beginQuery(filter: filter, authors: authors)
    }
  }

  func receive(_ event: NostrEvent, subscriptionID: String, relayURL: String) async {
    guard await eventDecoder.isValid(event), !Task.isCancelled else { return }
    guard isVisible, let owner, event.kind == .followList, event.pubkey != owner else { return }
    let isDiscovery =
      queries[subscriptionID]?.page != nil || subscriptionID == discoveryLiveSubscriptionID
    let isLive = subscriptionID == liveSubscriptionID && visibleAuthors.contains(event.pubkey)
    let query = queries[subscriptionID]
    guard isDiscovery || isLive || query?.authors?.contains(event.pubkey) == true else { return }
    guard !isDiscovery || event.referencedPubkeys.contains(owner) else { return }
    if var query {
      guard query.expectedRelays.contains(relayURL) else { return }
      guard query.page?.until.map({ event.createdAt <= $0 }) != false else { return }
      query.page?.record(id: event.id, timestamp: Int(event.createdAt))
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
    } else if let relayURL = query.expectedRelays.first, let page = query.page {
      pool?.closeSubscription(with: id)
      if failed {
        discoveryPages.removeValue(forKey: relayURL)
      } else {
        switch page.completion() {
        case .next(let next): discoveryPages[relayURL] = next
        case .finished: discoveryPages.removeValue(forKey: relayURL)
        case .incomplete:
          discoveryPages.removeValue(forKey: relayURL)
          queryFailed = true
        }
      }
      canLoadMore = !discoveryPages.isEmpty
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
