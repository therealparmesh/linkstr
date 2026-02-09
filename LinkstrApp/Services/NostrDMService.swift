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
          self?.handleIncomingEvent(relayEvent.event)
        }

      recipientFilter = Filter(
        kinds: [EventKind.giftWrap.rawValue],
        pubkeys: [keypair.publicKey.hex],
        limit: 2000
      )

      // Compatibility fallback: some clients/relays may expose gift-wrap queries better by author.
      authorFilter = Filter(
        authors: [keypair.publicKey.hex],
        kinds: [EventKind.giftWrap.rawValue],
        limit: 2000
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

  private func installSubscriptions() {
    guard let relayPool else { return }
    if let recipientFilter {
      _ = relayPool.subscribe(with: recipientFilter, subscriptionId: recipientSubscriptionID)
    }
    if let authorFilter {
      _ = relayPool.subscribe(with: authorFilter, subscriptionId: authorSubscriptionID)
    }
  }

  private func handleIncomingEvent(_ event: NostrEvent) {
    guard let keypair else { return }
    guard event.kind == .giftWrap else { return }

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
      onRelayStatus?(relay.url.absoluteString, .connected, nil)
    case .connecting:
      onRelayStatus?(relay.url.absoluteString, .disconnected, nil)
    case .notConnected:
      onRelayStatus?(relay.url.absoluteString, .disconnected, nil)
      scheduleReconnect()
    case .error(let error):
      onRelayStatus?(relay.url.absoluteString, .failed, error.localizedDescription)
      scheduleReconnect()
    }
  }

  func relay(_ relay: Relay, didReceive response: RelayResponse) {
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
  case payloadEncodingFailed
  case invalidPubkey

  var errorDescription: String? {
    switch self {
    case .missingIdentity:
      return "No active identity."
    case .payloadEncodingFailed:
      return "Unable to encode linkstr payload."
    case .invalidPubkey:
      return "Invalid recipient pubkey."
    }
  }
}
