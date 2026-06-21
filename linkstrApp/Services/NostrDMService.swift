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

struct ReceivedProfileMetadata {
  let eventID: String
  let authorPubkey: String
  let chosenName: String?
  let rawContent: String
  let createdAt: Date
}

enum NostrDMTimingDefaults {
  static let reconnectDelayNanoseconds: UInt64 = 2_000_000_000
  static let profileLookupTimeoutNanoseconds: UInt64 = 3_000_000_000
  static let relayAcceptanceTimeoutSeconds: TimeInterval = 8
  static let minimumRelayAcceptanceTimeoutSeconds: TimeInterval = 0.1
  /// NIP-59 gift-wrap `created_at` is randomized up to 2 days in the past.
  static let giftWrapTimestampObfuscationSeconds: Int = 172800
}

@MainActor
final class NostrDMService: NSObject, ObservableObject, EventCreating {
  enum BackfillSubscriptionKind: String {
    case recipient
    case author
  }

  struct BackfillState {
    let kind: BackfillSubscriptionKind
    var page: Int
    let until: Int?
    let pageSize: Int
    var expectedRelayURLs: Set<String>
    var eoseRelayURLs = Set<String>()
    var oldestCreatedAt: Int64?
    var receivedGiftWrapCount = 0
  }

  var relayPool: RelayPool?
  private var eventCancellable: AnyCancellable?
  var processedEventIDs = Set<String>()
  var processedEventIDOrder: [String] = []
  var processedEventIDHead = 0
  var processedGiftWrapEventIDs = Set<String>()
  var processedGiftWrapEventIDOrder: [String] = []
  var processedGiftWrapEventIDHead = 0
  private var recipientFilter: Filter?
  private var authorFilter: Filter?
  var reconnectTask: Task<Void, Never>?
  var shouldMaintainConnection = false
  var publishAckTracker = PublishAckTracker()
  var pendingPublishContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
  var pendingPublishBatchTimeoutTasks: [UUID: Task<Void, Never>] = [:]
  var liveSubscriptionSince: Int?

  var keypair: Keypair?
  var onIncoming: ((ReceivedDirectMessage) -> Void)?
  var onFollowList: ((ReceivedFollowList) -> Void)?
  var onProfileMetadata: ((ReceivedProfileMetadata) -> Void)?
  var onRelayStatus: ((String, RelayHealthStatus, String?) -> Void)?
  var onInitialBackfillComplete: (() -> Void)?
  var configuredRelayURLs = Set<String>()
  var didNotifyInitialBackfillCompletion = false

  let recipientSubscriptionID = "linkstr-giftwrap-recipient"
  let authorSubscriptionID = "linkstr-giftwrap-author"
  private let followListSubscriptionID = "linkstr-follow-list-self"
  let backfillPageSize = 500
  let processedEventIDLimit = 10_000
  var activeBackfillStates: [String: BackfillState] = [:]
  var completedBackfillKinds = Set<BackfillSubscriptionKind>()
  var currentBackfillRelayURLs = Set<String>()
  var completedBackfillRelayURLs = Set<String>()
  private var followListFilter: Filter?
  let payloadDecoder = JSONDecoder()
  let linkstrRumorKind = EventKind.unknown(44_001)

  // MARK: - Configuration

  func isConfigured(
    for keypair: Keypair,
    relayURLs: [String]
  ) -> Bool {
    guard shouldMaintainConnection, relayPool != nil else { return false }
    guard self.keypair?.publicKey.hex == keypair.publicKey.hex else { return false }
    return configuredRelayURLs == Set(relayURLs)
  }

  func start(
    keypair: Keypair,
    relayURLs: [String],
    onIncoming: @escaping (ReceivedDirectMessage) -> Void,
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void,
    onInitialBackfillComplete: (() -> Void)? = nil,
    onFollowList: ((ReceivedFollowList) -> Void)? = nil,
    onProfileMetadata: ((ReceivedProfileMetadata) -> Void)? = nil
  ) {
    if isConfigured(for: keypair, relayURLs: relayURLs) {
      self.onIncoming = onIncoming
      self.onRelayStatus = onRelayStatus
      self.onInitialBackfillComplete = onInitialBackfillComplete
      self.onFollowList = onFollowList
      self.onProfileMetadata = onProfileMetadata
      relayPool?.connect()
      return
    }

    stop()
    shouldMaintainConnection = true

    applyCallbacks(
      onIncoming: onIncoming,
      onRelayStatus: onRelayStatus,
      onInitialBackfillComplete: onInitialBackfillComplete,
      onFollowList: onFollowList,
      onProfileMetadata: onProfileMetadata
    )
    resetBackfillState(keypair: keypair, relayURLs: relayURLs)

    let validRelayURLs = reportInvalidRelays(relayURLs: relayURLs, onRelayStatus: onRelayStatus)
    guard !validRelayURLs.isEmpty else {
      onRelayStatus(
        relayURLs.first ?? "relays",
        .failed,
        "no valid relay urls are configured."
      )
      return
    }

    configureRelayPool(
      validRelayURLs: validRelayURLs, keypair: keypair, relayURLs: relayURLs,
      onRelayStatus: onRelayStatus)
  }

  private func applyCallbacks(
    onIncoming: @escaping (ReceivedDirectMessage) -> Void,
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void,
    onInitialBackfillComplete: (() -> Void)?,
    onFollowList: ((ReceivedFollowList) -> Void)?,
    onProfileMetadata: ((ReceivedProfileMetadata) -> Void)?
  ) {
    self.onIncoming = onIncoming
    self.onRelayStatus = onRelayStatus
    self.onInitialBackfillComplete = onInitialBackfillComplete
    self.onFollowList = onFollowList
    self.onProfileMetadata = onProfileMetadata
  }

  private func resetBackfillState(keypair: Keypair, relayURLs: [String]) {
    self.keypair = keypair
    configuredRelayURLs = Set(relayURLs)
    activeBackfillStates = [:]
    completedBackfillKinds = []
    currentBackfillRelayURLs = []
    completedBackfillRelayURLs = []
    didNotifyInitialBackfillCompletion = false
    liveSubscriptionSince =
      Int(Date.now.timeIntervalSince1970)
      - NostrDMTimingDefaults.giftWrapTimestampObfuscationSeconds
  }

  private func reportInvalidRelays(
    relayURLs: [String],
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void
  ) -> Set<URL> {
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
    return validRelayURLs
  }

  private func configureRelayPool(
    validRelayURLs: Set<URL>,
    keypair: Keypair,
    relayURLs: [String],
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void
  ) {
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

  // MARK: - Lifecycle

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
    currentBackfillRelayURLs.removeAll()
    completedBackfillRelayURLs.removeAll()
    didNotifyInitialBackfillCompletion = false
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
    onProfileMetadata = nil
    onRelayStatus = nil
    onInitialBackfillComplete = nil
    keypair = nil
    configuredRelayURLs.removeAll()
  }

  func scheduleReconnect() {
    guard shouldMaintainConnection else { return }
    guard reconnectTask == nil else { return }

    reconnectTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.reconnectTask = nil }
      try? await Task.sleep(nanoseconds: NostrDMTimingDefaults.reconnectDelayNanoseconds)
      guard !Task.isCancelled else { return }
      guard self.shouldMaintainConnection else { return }
      self.relayPool?.connect()
    }
  }

  // MARK: - Connection management

  func installSubscriptions() {
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

}

// MARK: - Errors

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
      return "invalid recipient public key (npub)."
    case .publishRejected(let message):
      return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "relay rejected this message."
        : message
    case .publishTimedOut:
      return "couldn't confirm send with relays. try again."
    }
  }
}
