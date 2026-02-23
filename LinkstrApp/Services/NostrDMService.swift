import Combine
import Foundation
import NostrSDK

struct ReceivedDirectMessage {
  let eventID: String
  let senderPubkey: String
  let receiverPubkey: String
  let payload: LinkstrPayload
  let createdAt: Date
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

  private struct PendingPublishAck {
    var expectedRelayURLs: Set<String>
    var failedRelayMessagesByURL: [String: String]
    let continuation: CheckedContinuation<Void, Error>
  }

  private var relayPool: RelayPool?
  private var eventCancellable: AnyCancellable?
  private var processedEventIDs = Set<String>()
  private var processedEventIDOrder: [String] = []
  private var recipientFilter: Filter?
  private var authorFilter: Filter?
  private var reconnectTask: Task<Void, Never>?
  private var shouldMaintainConnection = false
  private var pendingPublishAcks: [String: PendingPublishAck] = [:]
  private var pendingPublishAckTimeoutTasks: [String: Task<Void, Never>] = [:]

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

    let parsedRelayURLs = relayURLs.map { ($0, URL(string: $0)) }
    let validRelayURLs = Set(parsedRelayURLs.compactMap(\.1))
    let invalidRelayURLs = parsedRelayURLs.compactMap { rawValue, parsedURL in
      parsedURL == nil ? rawValue : nil
    }

    for invalidRelay in invalidRelayURLs {
      onRelayStatus(
        invalidRelay,
        .failed,
        "Invalid relay URL format: \(invalidRelay)"
      )
    }

    guard !validRelayURLs.isEmpty else {
      onRelayStatus(
        relayURLs.first ?? "relays",
        .failed,
        "No valid relay URLs are configured."
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
        limit: backfillPageSize
      )

      // Compatibility fallback: some clients/relays may expose gift-wrap queries better by author.
      authorFilter = Filter(
        authors: [keypair.publicKey.hex],
        kinds: [EventKind.giftWrap.rawValue],
        limit: backfillPageSize
      )

      followListFilter = Filter(
        authors: [keypair.publicKey.hex],
        kinds: [EventKind.followList.rawValue],
        limit: 1
      )

    } catch {
      let message = "Failed to start relay pool: \(error.localizedDescription)"
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
    recipientFilter = nil
    authorFilter = nil
    followListFilter = nil
    activeBackfillStates.removeAll()
    completedBackfillKinds.removeAll()
    let pendingEventIDs = Array(pendingPublishAcks.keys)
    for eventID in pendingEventIDs {
      finishPendingPublishAck(
        eventID: eventID,
        result: .failure(NostrServiceError.relayUnavailable)
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
  ) async throws -> String {
    guard relayPool != nil else {
      throw NostrServiceError.relayUnavailable
    }

    let events = try buildRumorAndGiftWrapEvents(
      payload: payload, recipientPubkeyHexes: recipientPubkeyHexes)
    guard let ackEventID = events.ackEventID else {
      throw NostrServiceError.relayUnavailable
    }
    let expectedRelayURLs = connectedRelayURLs()
    guard !expectedRelayURLs.isEmpty else {
      throw NostrServiceError.relayUnavailable
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      pendingPublishAcks[ackEventID] = PendingPublishAck(
        expectedRelayURLs: expectedRelayURLs,
        failedRelayMessagesByURL: [:],
        continuation: continuation
      )

      pendingPublishAckTimeoutTasks[ackEventID] = Task { @MainActor [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: .seconds(max(0.1, timeoutSeconds)))
        guard !Task.isCancelled else { return }
        self.finishPendingPublishAck(
          eventID: ackEventID,
          result: .failure(NostrServiceError.publishTimedOut)
        )
      }

      for giftWrap in events.giftWrapForRecipients {
        relayPool?.publishEvent(giftWrap)
      }
      if let giftWrapForSender = events.giftWrapForSender {
        relayPool?.publishEvent(giftWrapForSender)
      }
    }

    return events.rumorEvent.id
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
    let expectedRelayURLs = connectedRelayURLs()
    guard !expectedRelayURLs.isEmpty else {
      throw NostrServiceError.relayUnavailable
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      pendingPublishAcks[followEvent.id] = PendingPublishAck(
        expectedRelayURLs: expectedRelayURLs,
        failedRelayMessagesByURL: [:],
        continuation: continuation
      )

      pendingPublishAckTimeoutTasks[followEvent.id] = Task { @MainActor [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: .seconds(max(0.1, timeoutSeconds)))
        guard !Task.isCancelled else { return }
        self.finishPendingPublishAck(
          eventID: followEvent.id,
          result: .failure(NostrServiceError.publishTimedOut)
        )
      }

      relayPool?.publishEvent(followEvent)
    }

    return followEvent.id
  }

  private func parsePublicKeys(_ pubkeyHexes: [String]) throws -> [PublicKey] {
    var parsedPublicKeys: [PublicKey] = []
    var seen = Set<String>()
    for pubkeyHex in pubkeyHexes {
      let trimmed = pubkeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let key = PublicKey(hex: trimmed) else {
        throw NostrServiceError.invalidPubkey
      }
      guard !seen.contains(key.hex) else { continue }
      seen.insert(key.hex)
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
    giftWrapForSender: NostrEvent?,
    ackEventID: String?
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

    if payload.kind == .reaction {
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

    let ackEventID = giftWrapForSender?.id ?? giftWrapForRecipients.first?.id
    return (rumorEvent, giftWrapForRecipients, giftWrapForSender, ackEventID)
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

  private func finishPendingPublishAck(eventID: String, result: Result<Void, Error>) {
    guard let pending = pendingPublishAcks.removeValue(forKey: eventID) else { return }
    pendingPublishAckTimeoutTasks.removeValue(forKey: eventID)?.cancel()

    switch result {
    case .success:
      pending.continuation.resume()
    case .failure(let error):
      pending.continuation.resume(throwing: error)
    }
  }

  private func handlePublishAck(
    relayURL: String,
    eventID: String,
    success: Bool,
    message: String
  ) {
    guard var pending = pendingPublishAcks[eventID] else { return }

    if success {
      finishPendingPublishAck(eventID: eventID, result: .success(()))
      return
    }

    pending.failedRelayMessagesByURL[relayURL] = message
    pending.expectedRelayURLs.remove(relayURL)
    pendingPublishAcks[eventID] = pending

    if pending.expectedRelayURLs.isEmpty {
      let fallbackMessage =
        pending.failedRelayMessagesByURL.values.first ?? "Relays rejected this message."
      finishPendingPublishAck(
        eventID: eventID,
        result: .failure(NostrServiceError.publishRejected(fallbackMessage))
      )
    }
  }

  private func pruneRelayFromPublishWaitlists(relayURL: String) {
    for eventID in Array(pendingPublishAcks.keys) {
      guard var pending = pendingPublishAcks[eventID] else { continue }
      guard pending.expectedRelayURLs.remove(relayURL) != nil else { continue }
      pendingPublishAcks[eventID] = pending

      if pending.expectedRelayURLs.isEmpty {
        let message = pending.failedRelayMessagesByURL.values.first ?? "Relay connection dropped."
        finishPendingPublishAck(
          eventID: eventID,
          result: .failure(NostrServiceError.publishRejected(message))
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

  private func handleIncomingEvent(_ relayEvent: RelayEvent) {
    guard let keypair else { return }
    let event = relayEvent.event
    if event.kind == .followList {
      guard let followListEvent = event as? FollowListEvent else { return }
      guard !processedEventIDs.contains(followListEvent.id) else { return }
      rememberProcessedEventID(followListEvent.id)
      let followedPubkeys = followListEvent.followedPubkeys.compactMap { followed -> String? in
        PublicKey(hex: followed.lowercased())?.hex
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

    guard let wrapped = event as? GiftWrapEvent,
      let rumor = try? wrapped.unsealedRumor(using: keypair.privateKey)
    else {
      return
    }

    guard rumor.kind == linkstrRumorKind else { return }

    guard !processedEventIDs.contains(rumor.id) else { return }

    guard let data = rumor.content.data(using: .utf8),
      let payload = try? JSONDecoder().decode(LinkstrPayload.self, from: data),
      (try? payload.validated()) != nil
    else {
      return
    }

    rememberProcessedEventID(rumor.id)

    let receiver = keypair.publicKey.hex

    onIncoming?(
      ReceivedDirectMessage(
        eventID: rumor.id,
        senderPubkey: rumor.pubkey,
        receiverPubkey: receiver,
        payload: payload,
        createdAt: rumor.createdDate
      ))
  }

  private func rememberProcessedEventID(_ eventID: String) {
    guard processedEventIDs.insert(eventID).inserted else { return }
    processedEventIDOrder.append(eventID)

    let overflowCount = processedEventIDOrder.count - processedEventIDLimit
    guard overflowCount > 0 else { return }

    let overflowIDs = processedEventIDOrder.prefix(overflowCount)
    for overflowID in overflowIDs {
      processedEventIDs.remove(overflowID)
    }
    processedEventIDOrder.removeFirst(overflowCount)
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
      return "You're signed out. Sign in to continue."
    case .relayUnavailable:
      return "You're offline. Waiting for a relay connection."
    case .payloadEncodingFailed:
      return "Couldn't prepare this message. Try again."
    case .invalidPubkey:
      return "Invalid recipient Contact Key (npub)."
    case .publishRejected(let message):
      return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Relay rejected this message."
        : message
    case .publishTimedOut:
      return "Couldn't confirm send with relays. Try again."
    }
  }
}
