import Foundation
import NostrSDK

extension NostrDMService {
  func connectedRelayURLs() -> Set<String> {
    Set(relayPool?.relays.compactMap { relay in
      if case .connected = relay.state { return relay.url.absoluteString }
      return nil
    } ?? [])
  }

  func restartHistory(on relay: Relay) {
    cancelHistory(relayURL: relay.url.absoluteString)
    settledHistoryRelays.remove(relay.url.absoluteString)
    for kind in BackfillSubscriptionKind.allCases {
      beginBackfill(kind: kind, relay: relay, page: RelayHistoryPage())
    }
  }

  func beginBackfill(kind: BackfillSubscriptionKind, relay: Relay, page: RelayHistoryPage) {
    guard let keypair else { return }
    let filter: Filter?
    switch kind {
    case .recipient:
      filter = Filter(kinds: [EventKind.giftWrap.rawValue], pubkeys: [keypair.publicKey.hex],
                      until: page.until, limit: page.limit)
    case .preferences:
      filter = Filter(authors: [keypair.publicKey.hex], kinds: [PrivatePreferenceCodec.kind.rawValue],
                      until: page.until, limit: page.limit)
    }
    guard let filter else { return }
    let id = "linkstr-backfill-\(UUID().uuidString.lowercased())"
    activeBackfillStates[id] = BackfillState(kind: kind, relayURL: relay.url.absoluteString, page: page)
    do {
      try relay.subscribe(with: filter, subscriptionId: id)
      backfillTimeoutTasks[id] = Task { [weak self, weak relay] in
        do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        guard let self, let relay else { return }
        self.relayReceiver?.historyDeadline(relay, subscriptionID: id)
      }
    } catch {
      finishBackfill(subscriptionID: id, failed: true)
    }
  }

  func handleBackfillEOSE(relayURL: String, subscriptionID: String) {
    guard activeBackfillStates[subscriptionID]?.relayURL == relayURL else { return }
    finishBackfill(subscriptionID: subscriptionID, failed: false)
  }

  func finishBackfill(subscriptionID: String, failed: Bool) {
    guard let state = activeBackfillStates.removeValue(forKey: subscriptionID) else { return }
    backfillTimeoutTasks.removeValue(forKey: subscriptionID)?.cancel()
    let relay = relayPool?.relays.first { $0.url.absoluteString == state.relayURL }
    try? relay?.closeSubscription(with: subscriptionID)
    let completion = failed ? RelayHistoryPage.Completion.incomplete : state.page.completion()
    if case .next(let page) = completion, let relay {
      beginBackfill(kind: state.kind, relay: relay, page: page)
      return
    }
    if case .incomplete = completion {
      onRelayStatus?(state.relayURL, .connected, "couldn't finish loading relay history. reconnect to try again.")
    }
    if !activeBackfillStates.values.contains(where: { $0.relayURL == state.relayURL }) {
      settledHistoryRelays.insert(state.relayURL)
    }
    if state.kind == .preferences {
      let generation = receiveGeneration
      Task { [weak self] in
        guard let self, self.receiveGeneration == generation else { return }
        await self.onPrivatePreferencesReady?()
      }
    }
    notifyInitialBackfillCompletionIfNeeded()
  }

  func cancelHistory(relayURL: String) {
    for (id, state) in activeBackfillStates where state.relayURL == relayURL {
      if let relay = relayPool?.relays.first(where: { $0.url.absoluteString == relayURL }) {
        try? relay.closeSubscription(with: id)
      }
      backfillTimeoutTasks.removeValue(forKey: id)?.cancel()
      activeBackfillStates.removeValue(forKey: id)
    }
    settledHistoryRelays.insert(relayURL)
  }

  func notifyInitialBackfillCompletionIfNeeded() {
    guard !didNotifyInitialBackfillCompletion, activeBackfillStates.isEmpty,
      settledHistoryRelays.isSuperset(of: configuredRelayURLs) else { return }
    didNotifyInitialBackfillCompletion = true
    onInitialBackfillComplete?()
  }

  func trackBackfillProgress(for event: NostrEvent, subscriptionID: String) {
    guard var state = activeBackfillStates[subscriptionID] else { return }
    state.page.record(id: event.id, timestamp: Int(event.createdAt))
    activeBackfillStates[subscriptionID] = state
  }

  func matchesBackfill(_ event: NostrEvent, subscriptionID: String, relayURL: String) -> Bool {
    guard let state = activeBackfillStates[subscriptionID], state.relayURL == relayURL,
      let owner = keypair?.publicKey.hex else { return false }
    guard state.page.until.map({ event.createdAt <= $0 }) != false else { return false }
    switch state.kind {
    case .recipient: return event.kind == .giftWrap && event.referencedPubkeys.contains(owner)
    case .preferences: return event.kind == PrivatePreferenceCodec.kind && event.pubkey == owner
    }
  }
}
