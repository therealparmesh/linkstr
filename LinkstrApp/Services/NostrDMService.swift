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
  private var recipientFilter: Filter?
  private var authorFilter: Filter?
  private var reconnectTask: Task<Void, Never>?
  private var reconnectAttempt = 0
  private var shouldMaintainConnection = false

  private var keypair: Keypair?
  private var onIncoming: ((ReceivedDirectMessage) -> Void)?
  private var onRelayStatus: ((String, RelayHealthStatus, String?) -> Void)?

  private let recipientSubscriptionID = "linkstr-giftwrap-recipient"
  private let authorSubscriptionID = "linkstr-giftwrap-author"
  private let backfillPageSize = 500
  private var activeBackfillStates: [String: BackfillState] = [:]
  private var completedBackfillKinds = Set<BackfillSubscriptionKind>()
  // App-specific rumor kind carried inside NIP-59 gift wrap events.
  private let linkstrRumorKind = EventKind.unknown(44_001)

  func start(
    keypair: Keypair,
    relayURLs: [String],
    onIncoming: @escaping (ReceivedDirectMessage) -> Void,
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void
  ) {
    stop()
    shouldMaintainConnection = true

    self.keypair = keypair
    self.onIncoming = onIncoming
    self.onRelayStatus = onRelayStatus
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
    reconnectAttempt = 0
    eventCancellable?.cancel()
    eventCancellable = nil
    relayPool?.disconnect()
    relayPool = nil
    processedEventIDs.removeAll()
    recipientFilter = nil
    authorFilter = nil
    activeBackfillStates.removeAll()
    completedBackfillKinds.removeAll()
    onIncoming = nil
    onRelayStatus = nil
    keypair = nil
  }

  private func scheduleReconnect() {
    guard shouldMaintainConnection else { return }
    reconnectTask?.cancel()
    reconnectAttempt += 1
    let cappedAttempt = min(reconnectAttempt, 5)
    let delaySeconds = UInt64(1 << cappedAttempt)

    reconnectTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
      guard let self, self.shouldMaintainConnection else { return }
      self.relayPool?.connect()
    }
  }

  func send(payload: LinkstrPayload, to recipientPubkeyHex: String) throws -> String {
    guard let keypair else {
      throw NostrServiceError.missingIdentity
    }
    guard relayPool != nil else {
      throw NostrServiceError.relayUnavailable
    }

    try payload.validated()

    let contentData = try JSONEncoder().encode(payload)
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw NostrServiceError.payloadEncodingFailed
    }

    let recipientPublicKey = try parsePublicKey(recipientPubkeyHex)
    let recipientTag = try PubkeyTag(publicKey: recipientPublicKey)

    let builder = NostrEvent.Builder<NostrEvent>(kind: linkstrRumorKind)
      .appendTags(recipientTag.tag)
      .content(content)

    if payload.kind == .reply {
      let rootTag = try EventTag(eventId: payload.rootID, marker: .root)
      builder.appendTags(rootTag.tag)
    }

    let rumorEvent = builder.build(pubkey: keypair.publicKey)

    let giftWrapForRecipient = try giftWrap(
      withRumor: rumorEvent,
      toRecipient: recipientPublicKey,
      signedBy: keypair
    )

    let giftWrapForSender = try giftWrap(
      withRumor: rumorEvent,
      toRecipient: keypair.publicKey,
      signedBy: keypair
    )

    relayPool?.publishEvent(giftWrapForRecipient)
    relayPool?.publishEvent(giftWrapForSender)

    return rumorEvent.id
  }

  private func parsePublicKey(_ hex: String) throws -> PublicKey {
    guard let key = PublicKey(hex: hex) else {
      throw NostrServiceError.invalidPubkey
    }
    return key
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
      relayPool.relays
        .filter { relay in
          if case .connected = relay.state { return true }
          return false
        }
        .map { $0.url.absoluteString })
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
  }

  private func handleIncomingEvent(_ relayEvent: RelayEvent) {
    guard let keypair else { return }
    let event = relayEvent.event
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

    processedEventIDs.insert(rumor.id)

    let peer = rumor.referencedPubkeys.first(where: { $0 != rumor.pubkey }) ?? keypair.publicKey.hex
    let receiver = rumor.pubkey == keypair.publicKey.hex ? peer : keypair.publicKey.hex

    onIncoming?(
      ReceivedDirectMessage(
        eventID: rumor.id,
        senderPubkey: rumor.pubkey,
        receiverPubkey: receiver,
        payload: payload,
        createdAt: rumor.createdDate
      ))
  }
}

extension NostrDMService: @preconcurrency RelayDelegate {
  func relayStateDidChange(_ relay: Relay, state: Relay.State) {
    switch state {
    case .connected:
      // Retry installs after each relay connection. Initial install can race with socket startup.
      reconnectTask?.cancel()
      reconnectTask = nil
      reconnectAttempt = 0
      installSubscriptions()
      startBackfillIfNeeded()
      onRelayStatus?(relay.url.absoluteString, .connected, nil)
    case .connecting:
      onRelayStatus?(relay.url.absoluteString, .reconnecting, nil)
    case .notConnected:
      pruneRelayFromBackfillWaitlists(relayURL: relay.url.absoluteString)
      onRelayStatus?(relay.url.absoluteString, .reconnecting, nil)
      scheduleReconnect()
    case .error(let error):
      pruneRelayFromBackfillWaitlists(relayURL: relay.url.absoluteString)
      onRelayStatus?(relay.url.absoluteString, .reconnecting, error.localizedDescription)
      scheduleReconnect()
    }
  }

  func relay(_ relay: Relay, didReceive response: RelayResponse) {
    switch response {
    case .eose(let subscriptionID):
      handleBackfillEOSE(relayURL: relay.url.absoluteString, subscriptionID: subscriptionID)
    case .closed(let subscriptionID, _):
      completeBackfillPage(subscriptionID: subscriptionID)
    default:
      break
    }

    if case .ok(_, let success, let message) = response, !success {
      switch message.prefix {
      case .authRequired, .restricted:
        onRelayStatus?(relay.url.absoluteString, .readOnly, message.message)
      default:
        // Non-auth publish failures can be relay policy/content checks while the socket is still healthy.
        break
      }
    }
  }

  func relay(_ relay: Relay, didReceive event: RelayEvent) {}
}

enum NostrServiceError: Error, LocalizedError {
  case missingIdentity
  case relayUnavailable
  case payloadEncodingFailed
  case invalidPubkey

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
    }
  }
}
