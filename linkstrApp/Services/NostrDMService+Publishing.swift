import Foundation
import NostrSDK

extension NostrDMService {
  func sendAwaitingRelayAcceptance(
    payload: LinkstrPayload,
    toMany recipientPubkeyHexes: [String],
    timeoutSeconds: TimeInterval = NostrDMTimingDefaults.relayAcceptanceTimeoutSeconds
  ) async throws -> SentPayloadReceipt {
    guard relayPool != nil else {
      throw NostrServiceError.relayUnavailable
    }

    let events = try buildRumorAndGiftWrapEvents(
      payload: payload, recipientPubkeyHexes: recipientPubkeyHexes)
    let publishedEvents =
      events.giftWrapForRecipients
      + (events.giftWrapForSender.map { [$0] } ?? [])
    guard !publishedEvents.isEmpty else {
      throw NostrServiceError.relayUnavailable
    }
    let publishedEventIDs = try await publishEventsAwaitingRelayAcceptance(
      publishedEvents,
      timeoutSeconds: timeoutSeconds
    )

    return SentPayloadReceipt(
      rumorEventID: events.rumorEvent.id,
      publishedEventIDs: publishedEventIDs
    )
  }

  func publishFollowListAwaitingRelayAcceptance(
    followedPubkeyHexes: [String],
    timeoutSeconds: TimeInterval = NostrDMTimingDefaults.relayAcceptanceTimeoutSeconds
  ) async throws -> String {
    guard relayPool != nil else {
      throw NostrServiceError.relayUnavailable
    }
    guard let keypair else {
      throw NostrServiceError.missingIdentity
    }

    let parsedPubkeys = try parsePublicKeys(followedPubkeyHexes)
    let followEvent = try followList(withPubkeys: parsedPubkeys.map(\.hex), signedBy: keypair)
    _ = try await publishEventsAwaitingRelayAcceptance(
      [followEvent],
      timeoutSeconds: timeoutSeconds
    )

    return followEvent.id
  }

  func publishEventAwaitingRelayAcceptance(
    _ event: NostrEvent,
    timeoutSeconds: TimeInterval = NostrDMTimingDefaults.relayAcceptanceTimeoutSeconds
  ) async throws -> String {
    guard relayPool != nil else {
      throw NostrServiceError.relayUnavailable
    }

    _ = try await publishEventsAwaitingRelayAcceptance(
      [event],
      timeoutSeconds: timeoutSeconds
    )

    return event.id
  }

  @discardableResult
  func requestProfileMetadata(pubkeyHexes: [String]) -> Bool {
    guard let relayPool else { return false }
    let normalizedPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes)
    guard !normalizedPubkeys.isEmpty else { return false }
    let expectedRelayURLs = connectedRelayURLs()
    guard !expectedRelayURLs.isEmpty else { return false }
    guard
      let filter = Filter(
        authors: normalizedPubkeys,
        kinds: [EventKind.metadata.rawValue]
      )
    else {
      return false
    }

    let subscriptionID = "linkstr-profile-lookup-\(UUID().uuidString.lowercased())"
    _ = relayPool.subscribe(with: filter, subscriptionId: subscriptionID)
    Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: NostrDMTimingDefaults.profileLookupTimeoutNanoseconds)
      guard !Task.isCancelled else { return }
      self.relayPool?.closeSubscription(with: subscriptionID)
    }
    return true
  }

  // MARK: - Gift wrap construction

  func parsePublicKeys(_ pubkeyHexes: [String]) throws -> [PublicKey] {
    guard let normalizedPubkeys = NostrValueNormalizer.validatedNormalizedPubkeyHexes(pubkeyHexes)
    else {
      throw NostrServiceError.invalidPubkey
    }
    return try normalizedPubkeys.map { hex in
      guard let key = PublicKey(hex: hex) else { throw NostrServiceError.invalidPubkey }
      return key
    }
  }

  struct RumorAndGiftWrapResult {
    let rumorEvent: NostrEvent
    let giftWrapForRecipients: [NostrEvent]
    let giftWrapForSender: NostrEvent?
  }

  func buildRumorAndGiftWrapEvents(
    payload: LinkstrPayload,
    recipientPubkeyHexes: [String]
  ) throws -> RumorAndGiftWrapResult {
    guard let keypair else {
      throw NostrServiceError.missingIdentity
    }

    try payload.validated()

    let contentData = try JSONEncoder().encode(payload)
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw NostrServiceError.payloadEncodingFailed
    }

    let builder = NostrEvent.Builder<NostrEvent>(kind: linkstrRumorKind)
      .content(content)

    if payload.kind == .reaction || payload.kind == .rootDelete {
      let rootTag = try EventTag(eventId: payload.rootID, marker: .root)
      builder.appendTags(rootTag.tag)
    }

    let rumorEvent = builder.build(pubkey: keypair.publicKey)
    let recipientPublicKeys = try parsePublicKeys(recipientPubkeyHexes)
    guard !recipientPublicKeys.isEmpty else {
      throw NostrServiceError.invalidPubkey
    }

    var giftWrapForRecipients: [NostrEvent] = []
    giftWrapForRecipients.reserveCapacity(recipientPublicKeys.count)
    for recipientPublicKey in recipientPublicKeys {
      let giftWrap = try giftWrap(
        withRumor: rumorEvent,
        toRecipient: recipientPublicKey,
        signedBy: keypair
      )
      giftWrapForRecipients.append(giftWrap)
    }

    let senderNeedsEcho = recipientPublicKeys.contains { $0.hex == keypair.publicKey.hex } == false
    let giftWrapForSender: NostrEvent?
    if senderNeedsEcho {
      giftWrapForSender = try giftWrap(
        withRumor: rumorEvent,
        toRecipient: keypair.publicKey,
        signedBy: keypair
      )
    } else {
      giftWrapForSender = nil
    }
    return RumorAndGiftWrapResult(
      rumorEvent: rumorEvent,
      giftWrapForRecipients: giftWrapForRecipients,
      giftWrapForSender: giftWrapForSender
    )
  }

  // MARK: - Publish acknowledgement

  func publishEventsAwaitingRelayAcceptance(
    _ events: [NostrEvent],
    timeoutSeconds: TimeInterval = NostrDMTimingDefaults.relayAcceptanceTimeoutSeconds
  ) async throws -> [String] {
    let eventIDs = events.map(\.id)
    guard !eventIDs.isEmpty else {
      throw NostrServiceError.relayUnavailable
    }

    let expectedRelayURLs = connectedRelayURLs()
    guard !expectedRelayURLs.isEmpty else {
      throw NostrServiceError.relayUnavailable
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let batchID = publishAckTracker.registerBatch(
        eventIDs: eventIDs,
        expectedRelayURLs: expectedRelayURLs
      )
      pendingPublishContinuations[batchID] = continuation
      pendingPublishBatchTimeoutTasks[batchID] = Task { @MainActor [weak self] in
        guard let self else { return }
        try? await Task.sleep(
          for: .seconds(
            max(
              NostrDMTimingDefaults.minimumRelayAcceptanceTimeoutSeconds,
              timeoutSeconds
            )
          )
        )
        guard !Task.isCancelled else { return }
        self.finishPendingPublishBatch(
          batchID: batchID,
          result: .failure(NostrServiceError.publishTimedOut)
        )
      }

      for event in events {
        relayPool?.publishEvent(event)
      }
    }

    return eventIDs
  }

  func finishPendingPublishBatch(
    batchID: UUID,
    result: Result<Void, Error>,
    removeFromTracker: Bool = true
  ) {
    if removeFromTracker {
      publishAckTracker.removeBatch(batchID)
    }
    pendingPublishBatchTimeoutTasks.removeValue(forKey: batchID)?.cancel()
    guard let continuation = pendingPublishContinuations.removeValue(forKey: batchID) else {
      return
    }

    continuation.resume(with: result)
  }

  func handlePublishAck(
    relayURL: String,
    eventID: String,
    success: Bool,
    message: String
  ) {
    guard
      let completion = publishAckTracker.acknowledge(
        relayURL: relayURL,
        eventID: eventID,
        success: success,
        message: message
      )
    else {
      return
    }

    switch completion.outcome {
    case .succeeded:
      finishPendingPublishBatch(
        batchID: completion.batchID, result: .success(()), removeFromTracker: false)
    case .failed(let failureMessage):
      finishPendingPublishBatch(
        batchID: completion.batchID,
        result: .failure(NostrServiceError.publishRejected(failureMessage)),
        removeFromTracker: false
      )
    }
  }

  func pruneRelayFromPublishWaitlists(relayURL: String) {
    for completion in publishAckTracker.pruneRelay(relayURL) {
      switch completion.outcome {
      case .succeeded:
        finishPendingPublishBatch(
          batchID: completion.batchID, result: .success(()), removeFromTracker: false)
      case .failed(let failureMessage):
        finishPendingPublishBatch(
          batchID: completion.batchID,
          result: .failure(NostrServiceError.publishRejected(failureMessage)),
          removeFromTracker: false
        )
      }
    }
  }
}
