import Combine
import Foundation
import NostrSDK

// MARK: - Event dispatch & processing

extension NostrDMService {
  func directMessageSource(for subscriptionID: String) -> DirectMessageIngestSource {
    if subscriptionID.hasPrefix("linkstr-backfill-") {
      return .historical
    }
    return .live
  }

  func handleIncomingEvent(_ relayEvent: RelayEvent) {
    guard let keypair else { return }
    let event = relayEvent.event

    switch event.kind {
    case .followList:
      handleFollowListEvent(event)
      return
    case .metadata:
      handleMetadataEvent(event)
      return
    case .giftWrap:
      break
    default:
      return
    }

    trackBackfillProgress(for: relayEvent)
    processGiftWrap(event, keypair: keypair, subscriptionId: relayEvent.subscriptionId)
  }

  func processGiftWrap(_ event: NostrEvent, keypair: Keypair, subscriptionId: String) {
    guard let wrapped = event as? GiftWrapEvent else {
      return
    }
    guard rememberProcessedGiftWrapEventIDIfNeeded(wrapped.id) else { return }

    guard let rumor = try? wrapped.unsealedRumor(using: keypair.privateKey) else {
      return
    }

    guard rumor.kind == linkstrRumorKind else { return }

    guard let payload = decodeValidatedPayload(from: rumor.content) else {
      return
    }

    let alreadyProcessedRumor = processedEventIDs.contains(rumor.id)
    guard !alreadyProcessedRumor || payload.kind == .root else { return }
    if !alreadyProcessedRumor {
      rememberProcessedEventID(rumor.id)
    }

    onIncoming?(
      ReceivedDirectMessage(
        eventID: rumor.id,
        transportEventID: wrapped.id,
        senderPubkey: rumor.pubkey,
        payload: payload,
        createdAt: rumor.createdDate,
        source: directMessageSource(for: subscriptionId)
      ))
  }

  private func handleFollowListEvent(_ event: NostrEvent) {
    guard let followListEvent = event as? FollowListEvent else { return }
    guard rememberProcessedEventIDIfNeeded(followListEvent.id) else { return }
    let followedPubkeys = followListEvent.followedPubkeys.compactMap { followed in
      NostrValueNormalizer.normalizedPubkeyHex(followed)
    }
    onFollowList?(
      ReceivedFollowList(
        eventID: followListEvent.id,
        authorPubkey: followListEvent.pubkey,
        followedPubkeys: followedPubkeys,
        createdAt: followListEvent.createdDate
      ))
  }

  private func handleMetadataEvent(_ event: NostrEvent) {
    guard let metadataEvent = event as? MetadataEvent else { return }
    guard rememberProcessedEventIDIfNeeded(metadataEvent.id) else { return }
    onProfileMetadata?(
      ReceivedProfileMetadata(
        eventID: metadataEvent.id,
        authorPubkey: metadataEvent.pubkey,
        chosenName: NostrProfileMetadata.chosenName(from: metadataEvent),
        rawContent: metadataEvent.content,
        createdAt: metadataEvent.createdDate
      )
    )
  }

  // MARK: - Event ID tracking

  func decodeValidatedPayload(from content: String) -> LinkstrPayload? {
    guard let data = content.data(using: .utf8),
      let payload = try? payloadDecoder.decode(LinkstrPayload.self, from: data),
      (try? payload.validated()) != nil
    else {
      return nil
    }
    return payload
  }

  @discardableResult
  func rememberProcessedEventIDIfNeeded(_ eventID: String) -> Bool {
    guard processedEventIDs.insert(eventID).inserted else { return false }
    processedEventIDOrder.append(eventID)
    trimProcessedIDStorageIfNeeded(
      ids: &processedEventIDs,
      order: &processedEventIDOrder,
      head: &processedEventIDHead,
      limit: processedEventIDLimit
    )
    return true
  }

  func rememberProcessedEventID(_ eventID: String) {
    _ = rememberProcessedEventIDIfNeeded(eventID)
  }

  @discardableResult
  func rememberProcessedGiftWrapEventIDIfNeeded(_ eventID: String) -> Bool {
    guard processedGiftWrapEventIDs.insert(eventID).inserted else { return false }
    processedGiftWrapEventIDOrder.append(eventID)
    trimProcessedIDStorageIfNeeded(
      ids: &processedGiftWrapEventIDs,
      order: &processedGiftWrapEventIDOrder,
      head: &processedGiftWrapEventIDHead,
      limit: processedEventIDLimit
    )
    return true
  }

  func trimProcessedIDStorageIfNeeded(
    ids: inout Set<String>,
    order: inout [String],
    head: inout Int,
    limit: Int
  ) {
    let activeCount = order.count - head
    let overflowCount = activeCount - limit
    guard overflowCount > 0 else { return }

    let trimEnd = head + overflowCount
    for index in head..<trimEnd {
      ids.remove(order[index])
    }
    head = trimEnd

    if head >= 2_048, head * 2 >= order.count {
      order.removeFirst(head)
      head = 0
    }
  }

  // MARK: - Relay state handling

  private func handleRelayStateDidChange(relayURL: String, state: Relay.State) {
    switch state {
    case .connected:
      reconnectTask?.cancel()
      reconnectTask = nil
      installSubscriptions()
      maybeRestartBackfillForLateRelay(relayURL: relayURL)
      startBackfillIfNeeded()
      onRelayStatus?(relayURL, .connected, nil)
    case .connecting:
      onRelayStatus?(relayURL, .connecting, nil)
    case .notConnected:
      pruneRelayFromBackfillWaitlists(relayURL: relayURL)
      pruneRelayFromPublishWaitlists(relayURL: relayURL)
      onRelayStatus?(relayURL, .disconnected, nil)
      scheduleReconnect()
    case .error(let error):
      pruneRelayFromBackfillWaitlists(relayURL: relayURL)
      pruneRelayFromPublishWaitlists(relayURL: relayURL)
      onRelayStatus?(relayURL, .failed, error.localizedDescription)
      scheduleReconnect()
    }
  }

  private struct RelayCallbackParams {
    let relayURL: String
    let eoseSubscriptionID: String?
    let closedSubscriptionID: String?
    let readOnlyMessage: String?
    let okEventID: String?
    let okSuccess: Bool?
    let okMessage: String?
  }

  private func handleRelayResponse(_ params: RelayCallbackParams) {
    let relayURL = params.relayURL
    let eoseSubscriptionID = params.eoseSubscriptionID
    let closedSubscriptionID = params.closedSubscriptionID
    let readOnlyMessage = params.readOnlyMessage
    let okEventID = params.okEventID
    let okSuccess = params.okSuccess
    let okMessage = params.okMessage
    if let eoseSubscriptionID, activeBackfillStates[eoseSubscriptionID] != nil {
      handleBackfillEOSE(relayURL: relayURL, subscriptionID: eoseSubscriptionID)
    }
    if let closedSubscriptionID, activeBackfillStates[closedSubscriptionID] != nil {
      completeBackfillPage(subscriptionID: closedSubscriptionID)
    }
    if let readOnlyMessage {
      onRelayStatus?(relayURL, .readOnly, readOnlyMessage)
    }
    if let okEventID, let okSuccess, let okMessage {
      handlePublishAck(
        relayURL: relayURL,
        eventID: okEventID,
        success: okSuccess,
        message: okMessage
      )
    }
  }

  // MARK: - Testing

  #if DEBUG
    func simulateInitialBackfillCompletionForTesting() {
      activeBackfillStates.removeAll()
      completedBackfillKinds = [.recipient, .author]
      completedBackfillRelayURLs = configuredRelayURLs
      currentBackfillRelayURLs.removeAll()
      didNotifyInitialBackfillCompletion = false
      notifyInitialBackfillCompletionIfNeeded()
    }

    func seedBackfillCoverageForTesting(
      activeRelayURLs: [String] = [],
      completedRelayURLs: [String] = [],
      hasActiveBackfill: Bool,
      isCompleted: Bool
    ) {
      currentBackfillRelayURLs = Set(activeRelayURLs)
      completedBackfillRelayURLs = Set(completedRelayURLs)
      completedBackfillKinds = isCompleted ? [.recipient, .author] : []
      if hasActiveBackfill {
        activeBackfillStates = [
          "test-backfill": BackfillState(
            kind: .recipient,
            page: 0,
            until: nil,
            pageSize: backfillPageSize,
            expectedRelayURLs: Set(activeRelayURLs)
          )
        ]
      } else {
        activeBackfillStates.removeAll()
      }
    }

    func simulateLateRelayConnectionForTesting(_ relayURL: String) {
      maybeRestartBackfillForLateRelay(relayURL: relayURL)
    }

    func simulateBackfillCoverageFinalizationForTesting(
      relayURLs: [String],
      initialCompletionAlreadyNotified: Bool
    ) {
      currentBackfillRelayURLs = Set(relayURLs)
      activeBackfillStates.removeAll()
      completedBackfillKinds = [.recipient, .author]
      didNotifyInitialBackfillCompletion = initialCompletionAlreadyNotified
      finalizeBackfillCoverageIfNeeded()
      notifyInitialBackfillCompletionIfNeeded()
    }

    var testingCurrentBackfillRelayURLs: Set<String> {
      currentBackfillRelayURLs
    }

    var testingCompletedBackfillRelayURLs: Set<String> {
      completedBackfillRelayURLs
    }

    var testingActiveBackfillCount: Int {
      activeBackfillStates.count
    }

    var testingCompletedBackfillKindCount: Int {
      completedBackfillKinds.count
    }
  #endif
}

// MARK: - RelayDelegate

extension NostrDMService: RelayDelegate {
  nonisolated func relayStateDidChange(_ relay: Relay, state: Relay.State) {
    let relayURL = relay.url.absoluteString
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.handleRelayStateDidChange(relayURL: relayURL, state: state)
    }
  }

  nonisolated func relay(_ relay: Relay, didReceive response: RelayResponse) {
    let relayURL = relay.url.absoluteString
    var eoseSubscriptionID: String?
    var closedSubscriptionID: String?
    var readOnlyMessage: String?
    var okEventID: String?
    var okSuccess: Bool?
    var okMessage: String?

    switch response {
    case .eose(let subscriptionID):
      eoseSubscriptionID = subscriptionID
    case .closed(let subscriptionID, _):
      closedSubscriptionID = subscriptionID
    case .ok(let eventID, let success, let message):
      okEventID = eventID
      okSuccess = success
      okMessage = message.message
      if !success {
        switch message.prefix {
        case .authRequired, .restricted:
          readOnlyMessage = message.message
        default:
          break
        }
      }
    default:
      break
    }

    guard
      eoseSubscriptionID != nil
        || closedSubscriptionID != nil
        || readOnlyMessage != nil
        || okEventID != nil
    else {
      return
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      self.handleRelayResponse(
        RelayCallbackParams(
          relayURL: relayURL,
          eoseSubscriptionID: eoseSubscriptionID,
          closedSubscriptionID: closedSubscriptionID,
          readOnlyMessage: readOnlyMessage,
          okEventID: okEventID,
          okSuccess: okSuccess,
          okMessage: okMessage
        ))
    }
  }

  nonisolated func relay(_ relay: Relay, didReceive event: RelayEvent) {}
}
