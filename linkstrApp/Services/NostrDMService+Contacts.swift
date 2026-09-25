import Foundation
import NostrSDK

// A failed or incomplete fetch must not be presented as an empty contact list.
enum ContactListLoadState {
  case loading
  case ready
  case unavailable
}

extension NostrDMService {
  var connectedFollowListRelays: Set<String> {
    Set(relayPool?.relays.compactMap { relay in
      if case .connected = relay.state { return relay.url.absoluteString }
      return nil
    } ?? [])
  }

  func beginFollowListQuery(relayURLs: Set<String>) {
    followListTimeoutTask?.cancel()
    followListTimeoutTask = nil
    relayPool?.closeSubscription(with: followListSubscriptionID)
    followListSubscriptionID = "linkstr-follow-list-self-\(UUID().uuidString.lowercased())"
    pendingFollowListRelays = relayURLs
    followListQueryFailed = false
    processedFollowListEventID = nil
    guard !relayURLs.isEmpty else {
      contactListLoadState = .unavailable
      return
    }
    contactListLoadState = .loading
    let subscriptionID = followListSubscriptionID
    followListTimeoutTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
      guard let self, self.followListSubscriptionID == subscriptionID else { return }
      self.finishFollowListQuery(unavailable: true)
    }
  }

  func completeFollowListQuery(relayURL: String, subscriptionID: String, failed: Bool = false) {
    guard subscriptionID == followListSubscriptionID,
      pendingFollowListRelays.remove(relayURL) != nil else { return }
    followListQueryFailed = followListQueryFailed || failed
    if pendingFollowListRelays.isEmpty {
      finishFollowListQuery(unavailable: followListQueryFailed)
    }
  }

  func finishFollowListQuery(unavailable: Bool) {
    followListTimeoutTask?.cancel()
    followListTimeoutTask = nil
    pendingFollowListRelays.removeAll()
    contactListLoadState = unavailable ? .unavailable : .ready
  }
}
