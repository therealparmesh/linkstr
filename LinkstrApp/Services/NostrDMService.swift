import Combine
import Foundation
import NostrSDK

enum DirectMessageIngestSource {
  case live
  case historical
}

struct ReceivedDirectMessage {
  let eventID: String
  let transportEventID: String?
  let senderPubkey: String
  let payload: LinkstrPayload
  let createdAt: Date
  let source: DirectMessageIngestSource
}

struct SentPayloadReceipt: Equatable {
  let rumorEventID: String
  let publishedEventIDs: [String]
}

struct ReceivedFollowList {
  let eventID: String
  let authorPubkey: String
  let followedPubkeys: [String]
  let createdAt: Date
}

@MainActor
final class NostrDMService: NSObject, ObservableObject, EventCreating {
  private enum BackfillSubscriptionKind: String {
    case recipient
    case author
  }

  private struct BackfillState {
    let kind: BackfillSubscriptionKind
    var page: Int
    let until: Int?
    let pageSize: Int
    var expectedRelayURLs: Set<String>
    var eoseRelayURLs = Set<String>()
    var oldestCreatedAt: Int64?
    var receivedGiftWrapCount = 0
  }

  private var relayPool: RelayPool?
  private var eventCancellable: AnyCancellable?
  private var processedEventIDs = Set<String>()
  private var processedEventIDOrder: [String] = []
  private var processedEventIDHead = 0
  private var processedGiftWrapEventIDs = Set<String>()
  private var processedGiftWrapEventIDOrder: [String] = []
  private var processedGiftWrapEventIDHead = 0
  private var recipientFilter: Filter?
  private var authorFilter: Filter?
  private var reconnectTask: Task<Void, Never>?
  private var shouldMaintainConnection = false
  private var publishAckTracker = PublishAckTracker()
  private var pendingPublishContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var pendingPublishBatchTimeoutTasks: [UUID: Task<Void, Never>] = [:]
  private var liveSubscriptionSince: Int?

  private var keypair: Keypair?
  private var onIncoming: ((ReceivedDirectMessage) -> Void)?
  private var onFollowList: ((ReceivedFollowList) -> Void)?
  private var onRelayStatus: ((String, RelayHealthStatus, String?) -> Void)?
  private var configuredRelayURLs = Set<String>()

  private let recipientSubscriptionID = "linkstr-giftwrap-recipient"
  private let authorSubscriptionID = "linkstr-giftwrap-author"
  private let followListSubscriptionID = "linkstr-follow-list-self"
  private let backfillPageSize = 500
  private let processedEventIDLimit = 10_000
  private let reconnectDelayNanoseconds: UInt64 = 2_000_000_000
  private var activeBackfillStates: [String: BackfillState] = [:]
  private var completedBackfillKinds = Set<BackfillSubscriptionKind>()
  private var followListFilter: Filter?
  private let payloadDecoder = JSONDecoder()
  // App-specific rumor kind carried inside NIP-59 gift wrap events.
  private let linkstrRumorKind = EventKind.unknown(44_001)

  func hasConnectedRelays() -> Bool {
    guard let relayPool else { return false }
    return relayPool.relays.contains { relay in
      if case .connected = relay.state { return true }
      return false
    }
  }

  func isConfigured(for keypair: Keypair, relayURLs: [String]) -> Bool {
    guard shouldMaintainConnection, relayPool != nil else { return false }
    guard self.keypair?.publicKey.hex == keypair.publicKey.hex else { return false }
    return configuredRelayURLs == Set(relayURLs)
  }

  func start(
    keypair: Keypair,
    relayURLs: [String],
    onIncoming: @escaping (ReceivedDirectMessage) -> Void,
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void,
    onFollowList: ((ReceivedFollowList) -> Void)? = nil
  ) {
    if isConfigured(for: keypair, relayURLs: relayURLs) {
      self.onIncoming = onIncoming
      self.onRelayStatus = onRelayStatus
      self.onFollowList = onFollowList
      relayPool?.connect()
      return
    }

    stop()
    shouldMaintainConnection = true

    self.keypair = keypair
    self.onIncoming = onIncoming
    self.onRelayStatus = onRelayStatus
    self.onFollowList = onFollowList
    configuredRelayURLs = Set(relayURLs)
    activeBackfillStates = [:]
    completedBackfillKinds = []
    liveSubscriptionSince = Int(Date.now.timeIntervalSince1970)

    let parsedRelayURLs = relayURLs.map { ($0, URL(string: $0)) }
    let validRelayURLs = Set(parsedRelayURLs.compactMap(\.1))
    let invalidRelayURLs = parsedRelayURLs.compactMap { rawValue, parsedURL in
      parsedURL == nil ? rawValue : nil
    }

    for invalidRelay in invalidRelayURLs {
      onRelayStatus(
        invalidRelay,
        .failed,
        "invalid relay url format: \(invalidRelay)"
      )
    }

    guard !validRelayURLs.isEmpty else {
      onRelayStatus(
        relayURLs.first ?? "relays",
        .failed,
        "no valid relay urls are configured."
      )
      return
    }

    do {
      let relayPool = try RelayPool(relayURLs: validRelayURLs, delegate: self)
      self.relayPool = relayPool

      eventCancellable = relayPool.events
        .receive(on: DispatchQueue.main)
        .sink { [weak self] relayEvent in
          self?.handleIncomingEvent(relayEvent)
        }

      recipientFilter = Filter(
        kinds: [EventKind.giftWrap.rawValue],
        pubkeys: [keypair.publicKey.hex],
        since: liveSubscriptionSince,
        limit: backfillPageSize
      )

      // Compatibility fallback: some clients/relays may expose gift-wrap queries better by author.
      authorFilter = Filter(
        authors: [keypair.publicKey.hex],
        kinds: [EventKind.giftWrap.rawValue],
        since: liveSubscriptionSince,
        limit: backfillPageSize
      )

      followListFilter = Filter(
        authors: [keypair.publicKey.hex],
        kinds: [EventKind.followList.rawValue],
        limit: 1
      )

    } catch {
      let message = "failed to start relay pool: \(error.localizedDescription)"
      for relayURL in relayURLs {
        onRelayStatus(relayURL, .failed, message)
      }
    }
  }

  func stop() {
    shouldMaintainConnection = false
    reconnectTask?.cancel()
    reconnectTask = nil
    eventCancellable?.cancel()
    eventCancellable = nil
    relayPool?.disconnect()
    relayPool = nil
    processedEventIDs.removeAll()
    processedEventIDOrder.removeAll()
    processedEventIDHead = 0
    processedGiftWrapEventIDs.removeAll()
    processedGiftWrapEventIDOrder.removeAll()
    processedGiftWrapEventIDHead = 0
    recipientFilter = nil
    authorFilter = nil
    followListFilter = nil
    liveSubscriptionSince = nil
    activeBackfillStates.removeAll()
    completedBackfillKinds.removeAll()
    let pendingBatchIDs = publishAckTracker.cancelAll()
    for batchID in pendingBatchIDs {
      finishPendingPublishBatch(
        batchID: batchID,
        result: .failure(NostrServiceError.relayUnavailable),
        removeFromTracker: false
      )
    }
    onIncoming = nil
    onFollowList = nil
    onRelayStatus = nil
    keypair = nil
    configuredRelayURLs.removeAll()
  }

  private func scheduleReconnect() {
    guard shouldMaintainConnection else { return }
    guard reconnectTask == nil else { return }

    reconnectTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.reconnectTask = nil }
      try? await Task.sleep(nanoseconds: self.reconnectDelayNanoseconds)
      guard !Task.isCancelled else { return }
      guard self.shouldMaintainConnection else { return }
      self.relayPool?.connect()
    }
  }

  func sendAwaitingRelayAcceptance(
    payload: LinkstrPayload,
    toMany recipientPubkeyHexes: [String],
    timeoutSeconds: TimeInterval = 8
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
    timeoutSeconds: TimeInterval = 8
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
    timeoutSeconds: TimeInterval = 8
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

  private func parsePublicKeys(_ pubkeyHexes: [String]) throws -> [PublicKey] {
    guard let normalizedPubkeys = NostrValueNormalizer.validatedNormalizedPubkeyHexes(pubkeyHexes)
    else {
      throw NostrServiceError.invalidPubkey
    }
    var parsedPublicKeys: [PublicKey] = []
    parsedPublicKeys.reserveCapacity(normalizedPubkeys.count)
    for normalizedPubkey in normalizedPubkeys {
      guard let key = PublicKey(hex: normalizedPubkey) else {
        throw NostrServiceError.invalidPubkey
      }
      parsedPublicKeys.append(key)
    }
    return parsedPublicKeys
  }

  private func buildRumorAndGiftWrapEvents(
    payload: LinkstrPayload,
    recipientPubkeyHexes: [String]
  ) throws -> (
    rumorEvent: NostrEvent,
    giftWrapForRecipients: [NostrEvent],
    giftWrapForSender: NostrEvent?
  ) {
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
    return (rumorEvent, giftWrapForRecipients, giftWrapForSender)
  }

  private func backfillSubscriptionID(kind: BackfillSubscriptionKind, page: Int, until: Int?)
    -> String
  {
    if let until {
      return "linkstr-backfill-\(kind.rawValue)-\(page)-\(until)"
    }
    return "linkstr-backfill-\(kind.rawValue)-\(page)-latest"
  }

  private func makeBackfillFilter(kind: BackfillSubscriptionKind, pubkey: String, until: Int?)
    -> Filter?
  {
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

  private func connectedRelayURLs() -> Set<String> {
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

  private func publishEventsAwaitingRelayAcceptance(
    _ events: [NostrEvent],
    timeoutSeconds: TimeInterval = 8
  ) async throws -> [String] {
    let eventIDs = events.map(\.id)
    guard !eventIDs.isEmpty else {
      throw NostrServiceError.relayUnavailable
    }

    let expectedRelayURLs = connectedRelayURLs()
    guard !expectedRelayURLs.isEmpty else {
      throw NostrServiceError.relayUnavailable
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let batchID = publishAckTracker.registerBatch(
        eventIDs: eventIDs,
        expectedRelayURLs: expectedRelayURLs
      )
      pendingPublishContinuations[batchID] = continuation
      pendingPublishBatchTimeoutTasks[batchID] = Task { @MainActor [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: .seconds(max(0.1, timeoutSeconds)))
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

  private func finishPendingPublishBatch(
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

    switch result {
    case .success:
      continuation.resume()
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }

  private func handlePublishAck(
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

  private func pruneRelayFromPublishWaitlists(relayURL: String) {
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

  private func startBackfillIfNeeded() {
    guard let keypair else { return }
    guard activeBackfillStates.isEmpty else { return }
    guard completedBackfillKinds.count < 2 else { return }
    if !completedBackfillKinds.contains(.recipient) {
      beginBackfill(kind: .recipient, page: 0, until: nil, pubkey: keypair.publicKey.hex)
    }
    if !completedBackfillKinds.contains(.author) {
      beginBackfill(kind: .author, page: 0, until: nil, pubkey: keypair.publicKey.hex)
    }
  }

  private func beginBackfill(
    kind: BackfillSubscriptionKind,
    page: Int,
    until: Int?,
    pubkey: String
  ) {
    let expectedRelayURLs = connectedRelayURLs()
    guard !expectedRelayURLs.isEmpty else { return }
    guard let relayPool, let filter = makeBackfillFilter(kind: kind, pubkey: pubkey, until: until)
    else {
      completedBackfillKinds.insert(kind)
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

  private func completeBackfillPage(subscriptionID: String) {
    guard var state = activeBackfillStates.removeValue(forKey: subscriptionID) else { return }
    relayPool?.closeSubscription(with: subscriptionID)

    guard let keypair else {
      completedBackfillKinds.insert(state.kind)
      return
    }

    guard state.receivedGiftWrapCount >= state.pageSize else {
      completedBackfillKinds.insert(state.kind)
      return
    }
    guard let oldestCreatedAt = state.oldestCreatedAt, oldestCreatedAt > 0 else {
      completedBackfillKinds.insert(state.kind)
      return
    }

    let nextUntil = Int(oldestCreatedAt - 1)
    if let priorUntil = state.until, nextUntil >= priorUntil {
      completedBackfillKinds.insert(state.kind)
      return
    }

    state.page += 1
    beginBackfill(
      kind: state.kind, page: state.page, until: nextUntil, pubkey: keypair.publicKey.hex)
  }

  private func handleBackfillEOSE(relayURL: String, subscriptionID: String) {
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

  private func pruneRelayFromBackfillWaitlists(relayURL: String) {
    for key in Array(activeBackfillStates.keys) {
      guard var state = activeBackfillStates[key] else { continue }
      guard state.expectedRelayURLs.remove(relayURL) != nil else { continue }
      activeBackfillStates[key] = state
      if state.expectedRelayURLs.isEmpty {
        completeBackfillPage(subscriptionID: key)
      }
    }
  }

  private func installSubscriptions() {
    guard let relayPool else { return }
    if let recipientFilter {
      _ = relayPool.subscribe(with: recipientFilter, subscriptionId: recipientSubscriptionID)
    }
    if let authorFilter {
      _ = relayPool.subscribe(with: authorFilter, subscriptionId: authorSubscriptionID)
    }
    if let followListFilter {
      _ = relayPool.subscribe(with: followListFilter, subscriptionId: followListSubscriptionID)
    }
  }

  private func directMessageSource(for subscriptionID: String) -> DirectMessageIngestSource {
    if subscriptionID.hasPrefix("linkstr-backfill-") {
      return .historical
    }
    return .live
  }

  private func handleIncomingEvent(_ relayEvent: RelayEvent) {
    guard let keypair else { return }
    let event = relayEvent.event
    if event.kind == .followList {
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
      return
    }

    guard event.kind == .giftWrap else { return }

    if var backfill = activeBackfillStates[relayEvent.subscriptionId] {
      backfill.receivedGiftWrapCount += 1
      let createdAt = Int64(event.createdAt)
      if let oldest = backfill.oldestCreatedAt {
        backfill.oldestCreatedAt = min(oldest, createdAt)
      } else {
        backfill.oldestCreatedAt = createdAt
      }
      activeBackfillStates[relayEvent.subscriptionId] = backfill
    }

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
        source: directMessageSource(for: relayEvent.subscriptionId)
      ))
  }

  private func decodeValidatedPayload(from content: String) -> LinkstrPayload? {
    guard let data = content.data(using: .utf8),
      let payload = try? payloadDecoder.decode(LinkstrPayload.self, from: data),
      (try? payload.validated()) != nil
    else {
      return nil
    }
    return payload
  }

  @discardableResult
  private func rememberProcessedEventIDIfNeeded(_ eventID: String) -> Bool {
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

  private func rememberProcessedEventID(_ eventID: String) {
    _ = rememberProcessedEventIDIfNeeded(eventID)
  }

  @discardableResult
  private func rememberProcessedGiftWrapEventIDIfNeeded(_ eventID: String) -> Bool {
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

  private func trimProcessedIDStorageIfNeeded(
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

    // Compact rarely to avoid frequent O(n) array shifts while still bounding memory growth.
    if head >= 2_048, head * 2 >= order.count {
      order.removeFirst(head)
      head = 0
    }
  }

  private func handleRelayStateDidChange(relayURL: String, state: Relay.State) {
    switch state {
    case .connected:
      // Retry installs after each relay connection. Initial install can race with socket startup.
      reconnectTask?.cancel()
      reconnectTask = nil
      installSubscriptions()
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

  private func handleRelayResponse(
    relayURL: String,
    eoseSubscriptionID: String?,
    closedSubscriptionID: String?,
    readOnlyMessage: String?,
    okEventID: String?,
    okSuccess: Bool?,
    okMessage: String?
  ) {
    if let eoseSubscriptionID {
      handleBackfillEOSE(relayURL: relayURL, subscriptionID: eoseSubscriptionID)
    }
    if let closedSubscriptionID {
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
}

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
          // Non-auth publish failures can be relay policy/content checks while the socket is still healthy.
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
        relayURL: relayURL,
        eoseSubscriptionID: eoseSubscriptionID,
        closedSubscriptionID: closedSubscriptionID,
        readOnlyMessage: readOnlyMessage,
        okEventID: okEventID,
        okSuccess: okSuccess,
        okMessage: okMessage
      )
    }
  }

  nonisolated func relay(_ relay: Relay, didReceive event: RelayEvent) {}
}

enum NostrServiceError: Error, LocalizedError {
  case missingIdentity
  case relayUnavailable
  case payloadEncodingFailed
  case invalidPubkey
  case publishRejected(String)
  case publishTimedOut

  var errorDescription: String? {
    switch self {
    case .missingIdentity:
      return "you're signed out. sign in to continue."
    case .relayUnavailable:
      return "you're offline. waiting for a relay connection."
    case .payloadEncodingFailed:
      return "couldn't prepare this message. try again."
    case .invalidPubkey:
      return "invalid recipient contact key (npub)."
    case .publishRejected(let message):
      return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "relay rejected this message."
        : message
    case .publishTimedOut:
      return "couldn't confirm send with relays. try again."
    }
  }
}
