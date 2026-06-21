import Foundation
import NostrSDK

extension NostrDMService {
  func connectedRelayURLs() -> Set<String> {
    guard let relayPool else { return [] }
    return Set(
      relayPool.relays.compactMap { relay in
        if case .connected = relay.state {
          return relay.url.absoluteString
        }
        return nil
      }
    )
  }

  func backfillSubscriptionID(kind: BackfillSubscriptionKind, page: Int, until: Int?) -> String {
    if let until {
      return "linkstr-backfill-\(kind.rawValue)-\(page)-\(until)"
    }
    return "linkstr-backfill-\(kind.rawValue)-\(page)-latest"
  }

  func makeBackfillFilter(kind: BackfillSubscriptionKind, pubkey: String, until: Int?) -> Filter? {
    switch kind {
    case .recipient:
      return Filter(
        kinds: [EventKind.giftWrap.rawValue],
        pubkeys: [pubkey],
        until: until,
        limit: backfillPageSize
      )
    case .author:
      return Filter(
        authors: [pubkey],
        kinds: [EventKind.giftWrap.rawValue],
        until: until,
        limit: backfillPageSize
      )
    }
  }

  // MARK: - Backfill state machine

  func startBackfillIfNeeded() {
    guard let keypair else { return }
    guard activeBackfillStates.isEmpty else { return }
    guard completedBackfillKinds.count < 2 else { return }
    let expectedRelayURLs = connectedRelayURLs()
    guard !expectedRelayURLs.isEmpty else { return }
    currentBackfillRelayURLs = expectedRelayURLs
    if !completedBackfillKinds.contains(.recipient) {
      beginBackfill(kind: .recipient, page: 0, until: nil, pubkey: keypair.publicKey.hex)
    }
    if !completedBackfillKinds.contains(.author) {
      beginBackfill(kind: .author, page: 0, until: nil, pubkey: keypair.publicKey.hex)
    }
  }

  func beginBackfill(
    kind: BackfillSubscriptionKind,
    page: Int,
    until: Int?,
    pubkey: String
  ) {
    let currentlyConnectedRelayURLs = connectedRelayURLs()
    let expectedRelayURLs: Set<String>
    if currentBackfillRelayURLs.isEmpty {
      expectedRelayURLs = currentlyConnectedRelayURLs
    } else {
      expectedRelayURLs = currentBackfillRelayURLs.intersection(currentlyConnectedRelayURLs)
    }
    guard !expectedRelayURLs.isEmpty else { return }
    guard let relayPool, let filter = makeBackfillFilter(kind: kind, pubkey: pubkey, until: until)
    else {
      markBackfillKindCompleted(kind)
      return
    }
    let subscriptionID = backfillSubscriptionID(kind: kind, page: page, until: until)
    activeBackfillStates[subscriptionID] = BackfillState(
      kind: kind,
      page: page,
      until: until,
      pageSize: backfillPageSize,
      expectedRelayURLs: expectedRelayURLs
    )
    _ = relayPool.subscribe(with: filter, subscriptionId: subscriptionID)
  }

  // MARK: - Pagination

  func completeBackfillPage(subscriptionID: String) {
    guard var state = activeBackfillStates.removeValue(forKey: subscriptionID) else { return }
    relayPool?.closeSubscription(with: subscriptionID)

    guard let keypair else {
      markBackfillKindCompleted(state.kind)
      return
    }

    guard state.receivedGiftWrapCount >= state.pageSize else {
      markBackfillKindCompleted(state.kind)
      return
    }
    guard let oldestCreatedAt = state.oldestCreatedAt, oldestCreatedAt > 0 else {
      markBackfillKindCompleted(state.kind)
      return
    }

    let nextUntil = Int(oldestCreatedAt - 1)
    if let priorUntil = state.until, nextUntil >= priorUntil {
      markBackfillKindCompleted(state.kind)
      return
    }

    state.page += 1
    beginBackfill(
      kind: state.kind, page: state.page, until: nextUntil, pubkey: keypair.publicKey.hex)
  }

  func markBackfillKindCompleted(_ kind: BackfillSubscriptionKind) {
    completedBackfillKinds.insert(kind)
    finalizeBackfillCoverageIfNeeded()
    notifyInitialBackfillCompletionIfNeeded()
  }

  func finalizeBackfillCoverageIfNeeded() {
    guard activeBackfillStates.isEmpty else { return }
    guard completedBackfillKinds.count == 2 else { return }
    completedBackfillRelayURLs = currentBackfillRelayURLs
    currentBackfillRelayURLs.removeAll()
  }

  func notifyInitialBackfillCompletionIfNeeded() {
    guard !didNotifyInitialBackfillCompletion else { return }
    guard activeBackfillStates.isEmpty else { return }
    guard completedBackfillKinds.count == 2 else { return }
    didNotifyInitialBackfillCompletion = true
    onInitialBackfillComplete?()
  }

  // MARK: - EOSE handling

  func handleBackfillEOSE(relayURL: String, subscriptionID: String) {
    guard var state = activeBackfillStates[subscriptionID] else { return }

    if state.expectedRelayURLs.isEmpty {
      state.expectedRelayURLs = connectedRelayURLs()
    }
    state.eoseRelayURLs.insert(relayURL)
    activeBackfillStates[subscriptionID] = state

    guard !state.expectedRelayURLs.isEmpty else {
      completeBackfillPage(subscriptionID: subscriptionID)
      return
    }
    if state.eoseRelayURLs.isSuperset(of: state.expectedRelayURLs) {
      completeBackfillPage(subscriptionID: subscriptionID)
    }
  }

  func pruneRelayFromBackfillWaitlists(relayURL: String) {
    currentBackfillRelayURLs.remove(relayURL)
    for key in Array(activeBackfillStates.keys) {
      guard var state = activeBackfillStates[key] else { continue }
      guard state.expectedRelayURLs.remove(relayURL) != nil else { continue }
      activeBackfillStates[key] = state
      if state.expectedRelayURLs.isEmpty {
        completeBackfillPage(subscriptionID: key)
      }
    }
  }

  // MARK: - Late relay recovery

  func resetBackfillProgressForLateRelay() {
    for subscriptionID in activeBackfillStates.keys {
      relayPool?.closeSubscription(with: subscriptionID)
    }
    activeBackfillStates.removeAll()
    completedBackfillKinds.removeAll()
    currentBackfillRelayURLs.removeAll()
    completedBackfillRelayURLs.removeAll()
  }

  func maybeRestartBackfillForLateRelay(relayURL: String) {
    if !activeBackfillStates.isEmpty {
      guard !currentBackfillRelayURLs.isEmpty else { return }
      guard !currentBackfillRelayURLs.contains(relayURL) else { return }
      resetBackfillProgressForLateRelay()
      return
    }

    guard completedBackfillKinds.count == 2 else { return }
    guard !completedBackfillRelayURLs.contains(relayURL) else { return }
    resetBackfillProgressForLateRelay()
  }

  // MARK: - Progress tracking

  func trackBackfillProgress(for relayEvent: RelayEvent) {
    if var backfill = activeBackfillStates[relayEvent.subscriptionId] {
      backfill.receivedGiftWrapCount += 1
      let createdAt = Int64(relayEvent.event.createdAt)
      if let oldest = backfill.oldestCreatedAt {
        backfill.oldestCreatedAt = min(oldest, createdAt)
      } else {
        backfill.oldestCreatedAt = createdAt
      }
      activeBackfillStates[relayEvent.subscriptionId] = backfill
    }
  }
}
