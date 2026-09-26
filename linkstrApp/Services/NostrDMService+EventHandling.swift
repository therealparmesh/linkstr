import Foundation
import NostrSDK

// MARK: - Event dispatch & processing

extension NostrDMService {
  func authenticate(to relay: Relay, challenge: String) {
    guard let keypair, relayPool?.relays.contains(where: { $0 === relay }) == true else { return }
    let relayURL = relay.url.absoluteString
    do {
      let event = try AuthenticationEvent.Builder()
        .relayURL(relay.url).challenge(challenge).build(signedBy: keypair)
      let data = try JSONEncoder().encode(event)
      guard let request = String(data: data, encoding: .utf8) else { return }
      pendingAuthenticationEvents = pendingAuthenticationEvents.filter { $0.value != relayURL }
      pendingAuthenticationEvents[event.id] = relayURL
      relay.send(request: "[\"AUTH\",\(request)]")
    } catch {
      onRelayStatus?(relayURL, .readOnly, error.localizedDescription)
    }
  }

  func directMessageSource(for subscriptionID: String) -> DirectMessageIngestSource {
    if subscriptionID.hasPrefix("linkstr-backfill-") {
      return .historical
    }
    return .live
  }

  func handleIncomingEvent(_ event: NostrEvent, subscriptionID: String) async {
    guard let keypair else { return }
    let generation = receiveGeneration
    let decoded = await eventDecoder.decode(
      event, keypair: keypair, source: directMessageSource(for: subscriptionID),
      skipGiftWrap: processedGiftWrapEventIDs.contains(event.id)
    )
    guard !Task.isCancelled, generation == receiveGeneration, let decoded else { return }
    await applyDecodedEvent(decoded, event: event, subscriptionID: subscriptionID, keypair: keypair)
  }

  private func applyDecodedEvent(
    _ decoded: NostrEventDecoder.DecodedEvent, event: NostrEvent, subscriptionID: String, keypair: Keypair
  ) async {
    if event.kind == PrivatePreferenceCodec.kind {
      if event.pubkey == keypair.publicKey.hex,
        event.firstValueForRawTagName("d")?.hasPrefix(PrivatePreferenceCodec.namespace) == true {
        await onPrivatePreference?(event)
      }
      return
    }

    switch event.kind {
    case .followList:
      if event.pubkey == keypair.publicKey.hex { handleFollowListEvent(event) }
    case .metadata:
      handleMetadataEvent(event)
    case .giftWrap:
      trackBackfillProgress(for: event, subscriptionID: subscriptionID)
      guard let message = decoded.message,
        rememberProcessedGiftWrapEventIDIfNeeded(event.id) else { return }
      let isNewRumor = rememberProcessedEventIDIfNeeded(message.eventID)
      guard isNewRumor || message.payload.kind == .root else { return }
      onIncoming?(message)
    default:
      break
    }
  }

  private func handleFollowListEvent(_ event: NostrEvent) {
    guard let followListEvent = event as? FollowListEvent else { return }
    guard processedFollowListEventID != followListEvent.id else { return }
    processedFollowListEventID = followListEvent.id
    let followedPubkeys = followListEvent.followedPubkeys.compactMap { followed in
      NostrValueNormalizer.normalizedPubkeyHex(followed)
    }
    onFollowList?(
      ReceivedFollowList(
        eventID: followListEvent.id,
        authorPubkey: followListEvent.pubkey,
        followedPubkeys: followedPubkeys,
        createdAt: followListEvent.createdDate, tags: followListEvent.tags
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

  func clearProcessedEventHistory() {
    processedEventIDs.removeAll()
    processedEventIDOrder.removeAll()
    processedEventIDHead = 0
    processedGiftWrapEventIDs.removeAll()
    processedGiftWrapEventIDOrder.removeAll()
    processedGiftWrapEventIDHead = 0
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
      if let relayPool { contactDiscovery?.connect(relayPool) }
      onRelayStatus?(relayURL, .connected, nil)
    case .connecting:
      onRelayStatus?(relayURL, .connecting, nil)
    case .notConnected:
      completeFollowListQuery(relayURL: relayURL, subscriptionID: followListSubscriptionID, failed: true)
      contactDiscovery?.relayDisconnected(relayURL)
      pruneRelayFromBackfillWaitlists(relayURL: relayURL)
      pruneRelayFromPublishWaitlists(relayURL: relayURL)
      onRelayStatus?(relayURL, .disconnected, nil)
      scheduleReconnect()
    case .error(let error):
      completeFollowListQuery(relayURL: relayURL, subscriptionID: followListSubscriptionID, failed: true)
      contactDiscovery?.relayDisconnected(relayURL)
      pruneRelayFromBackfillWaitlists(relayURL: relayURL)
      pruneRelayFromPublishWaitlists(relayURL: relayURL)
      onRelayStatus?(relayURL, .failed, error.localizedDescription)
      scheduleReconnect()
    }
  }

}

// MARK: - Ordered relay delivery

extension NostrDMService {
  func makeRelayReceiver() -> NostrRelayReceiver {
    NostrRelayReceiver { [weak self] relay, response in
      Task { @MainActor [weak self] in
        guard let self, self.relayPool?.relays.contains(where: { $0 === relay }) == true else { return }
        await self.receive(response, from: relay)
      }
    }
  }

  func startReceiving(from receiver: NostrRelayReceiver) {
    relayReceiver = receiver
    let stream = receiver.stream
    receiveTask = Task { @MainActor [weak self] in
      for await input in stream {
        guard !Task.isCancelled, let self else { return }
        switch input {
        case .state(let relay, let state):
          guard self.relayPool?.relays.contains(where: { $0 === relay }) == true else { continue }
          self.handleRelayStateDidChange(relayURL: relay.url.absoluteString, state: state)
        case .response(let relay, let response):
          guard self.relayPool?.relays.contains(where: { $0 === relay }) == true else { continue }
          await self.receive(response, from: relay)
        }
        await Task.yield()
      }
    }
  }

  private func receive(_ response: RelayResponse, from relay: Relay) async {
    let relayURL = relay.url.absoluteString
    switch response {
    case .event(let subscriptionID, let event):
      if event.kind == .followList, event.pubkey != keypair?.publicKey.hex {
        await contactDiscovery?.receive(event, subscriptionID: subscriptionID, relayURL: relayURL)
      } else {
        await handleIncomingEvent(event, subscriptionID: subscriptionID)
      }
    case .auth(let challenge):
      authenticate(to: relay, challenge: challenge)
    case .eose(let subscriptionID):
      if subscriptionID == privatePreferencesSubscriptionID {
        await onPrivatePreferencesReady?()
      } else {
        handleBackfillEOSE(relayURL: relayURL, subscriptionID: subscriptionID)
        completeFollowListQuery(relayURL: relayURL, subscriptionID: subscriptionID)
        contactDiscovery?.complete(relayURL: relayURL, subscriptionID: subscriptionID)
        completeProfileQuery(relayURL: relayURL, subscriptionID: subscriptionID)
      }
    case .closed(let subscriptionID, _):
      completeBackfillPage(subscriptionID: subscriptionID)
      completeFollowListQuery(relayURL: relayURL, subscriptionID: subscriptionID, failed: true)
      contactDiscovery?.complete(relayURL: relayURL, subscriptionID: subscriptionID, failed: true)
      completeProfileQuery(relayURL: relayURL, subscriptionID: subscriptionID, failed: true)
    case .ok(let eventID, let success, let message):
      receiveAcknowledgment(eventID: eventID, success: success, message: message, relayURL: relayURL)
    default:
      break
    }
  }

  private func receiveAcknowledgment(
    eventID: String, success: Bool, message: RelayResponse.Message, relayURL: String
  ) {
    if pendingAuthenticationEvents[eventID] == relayURL {
      pendingAuthenticationEvents.removeValue(forKey: eventID)
      if success {
        onRelayStatus?(relayURL, .connected, nil)
        installSubscriptions()
        if let relayPool { contactDiscovery?.connect(relayPool) }
      }
      return
    }
    if !success, message.prefix == .authRequired || message.prefix == .restricted {
      onRelayStatus?(relayURL, .readOnly, message.message)
    }
    handlePublishAck(relayURL: relayURL, eventID: eventID, success: success, message: message.message)
  }
}
