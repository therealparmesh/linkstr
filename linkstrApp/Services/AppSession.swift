import Foundation
import NostrSDK
import SwiftData

#if canImport(UIKit)
  import UIKit
#endif

enum RelayMutationDefaults {
  static let timeoutSeconds: TimeInterval = 12
  static let pollIntervalSeconds: TimeInterval = 0.25
}

struct SessionSnapshotParams {
  let ownerPubkey: String
  let sessionID: String
  let createdByPubkey: String
  let sessionName: String?
  let memberPubkeys: [String]
  let updatedAt: Date
  let eventID: String
  var isArchived: Bool?
}

enum AppSessionTimingDefaults {
  static let remoteProfileLookupRetryNanoseconds: UInt64 = 3_000_000_000
  static let passiveOfflineToastGraceInterval: TimeInterval = 1
  static let identityRetryDelayNanoseconds: UInt64 = 250_000_000
}

enum IdentityLoadRetryDefaults {
  static let bootAttempts = 2
  static let protectedDataUnavailableBootAttempts = 6
  static let activeAttempts = 2
  static let protectedDataAttempts = 4
}

@MainActor
final class AppSession: ObservableObject {
  struct SessionNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
  }

  struct FormMutationResult {
    let didSucceed: Bool
    let errorMessage: String?
  }

  enum RelayConnectivityState: Equatable {
    case noEnabledRelays
    case online
    case connecting
    case readOnly
    case offline
  }

  struct RelayRuntimeStatus {
    var status: RelayHealthStatus
    var message: String?
  }

  struct PendingMetadataRefresh {
    let storageID: String
  }

  struct PendingIncomingMessage {
    let incoming: ReceivedDirectMessage
    private(set) var transportEventIDs: [String]

    init(_ incoming: ReceivedDirectMessage) {
      self.incoming = incoming
      self.transportEventIDs = Self.mergedTransportEventIDs(
        [],
        incoming.transportEventID.map { [$0] } ?? []
      )
    }

    var eventID: String { incoming.eventID }

    mutating func mergeDuplicate(_ duplicate: ReceivedDirectMessage) {
      guard incoming.eventID == duplicate.eventID else { return }
      transportEventIDs = Self.mergedTransportEventIDs(
        transportEventIDs,
        duplicate.transportEventID.map { [$0] } ?? []
      )
    }

    private static func mergedTransportEventIDs(_ first: [String], _ second: [String]) -> [String] {
      NostrValueNormalizer.dedupedNormalizedEventIDs(first + second)
    }
  }

  enum IncomingPersistenceOutcome {
    case applied
    case ignored
    case pending
  }

  enum InboundSessionResolution {
    case ready(SessionEntity)
    case pending
    case ignored
  }

  struct RootPostDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let recipientPubkeys: [String]
    let normalizedURL: String
  }

  struct ReactionDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let recipientPubkeys: [String]
  }

  struct RootDeletionDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let recipientPubkeys: [String]
    let rootID: String
    let publishedTransportEventIDs: [String]
  }

  struct SessionDeletionDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let recipientPubkeys: [String]
    let sessionID: String
    let hadStoredRootPosts: Bool
    let publishedTransportEventIDs: [String]
  }

  struct TestingOverrides {
    var disableNostrStartup: Bool?
    var hasConnectedRelays: (() -> Bool)?
    var passiveOfflineToastGraceInterval: TimeInterval?
    var loadIdentity: ((IdentityService) -> IdentityService.LoadResult)?
    var identityRetryDelayNanoseconds: UInt64?
    var skipPersistedFollowListStateLoad = false
    var publishFollowList: (([String]) async throws -> String)?
    var publishRelayEvent: ((NostrEvent) async throws -> String)?
    var sendPayload: ((LinkstrPayload, [String]) async throws -> SentPayloadReceipt)?
    var skipNostrNetworkStartup = false
    var onNostrStart: (() -> Void)?
    var requestProfileMetadata: (([String]) -> Bool)?
    var remoteProfileLookupRetryNanoseconds: UInt64?
    var clearLocalAccountData: ((String) throws -> Void)?
    var registerPushDevice: ((PushDeviceRegistration) async throws -> Void)?
    var unregisterPushDevice: ((String) async throws -> Void)?
    var syncArchivedConversationIDs: (([String]) async throws -> Void)?
    var enqueuePushNotification: ((PushEnqueueRequest) async throws -> Void)?
    var fetchLinkPreview: ((String) async -> LinkPreviewData?)?
  }

  enum MutationPreparationError: Error {
    case relayBlocked
  }

  struct LocalAccountCleanupError: LocalizedError {
    let failures: [String]

    var errorDescription: String? {
      guard !failures.isEmpty else { return nil }
      if failures.count == 1 {
        return failures[0]
      }
      return "local cleanup did not fully complete: \(failures.joined(separator: " "))"
    }
  }

  struct ValidatedSessionCreateInputs {
    let sessionID: String
    let members: [String]
  }

  struct ValidatedReactionInputs {
    let sessionID: String
    let postID: String
    let emoji: String
    let isActive: Bool
  }

  struct InsertOrUpdateRootPostParams {
    let incoming: ReceivedDirectMessage
    let ownerPubkey: String
    let sessionID: String
    let normalizedURL: String
    let existingSession: SessionEntity
    let transportEventIDs: [String]
  }

  enum RelaySendWaitState {
    case ready
    case blocked(message: String)
    case waitingForConnection
  }

  // MARK: - Stored Properties

  let identityService: IdentityService
  let modelContext: ModelContext
  let contactStore: ContactStore
  let relayStore: RelayStore
  let messageStore: SessionMessageStore
  let accountStateStore: AccountStateStore
  let testingOverrides: TestingOverrides
  var nostrService: NostrDMService
  let noEnabledRelaysMessage =
    "no relays are enabled. enable at least one relay in settings."
  let relayOfflineMessage = "you're offline. waiting for a relay connection."
  let relayReadOnlyMessage =
    "connected relays are read-only. add a writable relay to send."
  let relaySendTimeoutMessage = "couldn't reconnect to relays in time. try again."
  var hasShownOfflineToastForCurrentOutage = false
  var isForeground = false
  var pendingMetadataRefreshes: [PendingMetadataRefresh] = []
  var pendingMetadataRefreshHead = 0
  var enqueuedMetadataStorageIDs = Set<String>()
  var isProcessingMetadataQueue = false
  var activeMetadataRefreshStorageID: String?
  var metadataRefreshQueueGeneration = 0
  @Published var relayRuntimeStatusByURL: [String: RelayRuntimeStatus] = [:]
  var pendingOfflineToastTask: Task<Void, Never>?
  var nostrStartupTask: Task<Void, Never>?
  var observedHealthyRelayThisForeground = false
  var suppressedComposeErrorPresentationCount = 0
  var nostrStartupGeneration = 0
  var passiveOfflineToastGraceUntil: Date?
  var latestAppliedFollowListCreatedAt: Date?
  var latestAppliedFollowListEventID: String?
  var latestAppliedProfileMetadataCreatedAt: Date?
  var latestAppliedProfileMetadataEventID: String?
  var currentProfileMetadataContent: String?
  var inFlightRemoteProfilePubkeys = Set<String>()
  var pendingRemoteProfilePubkeys = Set<String>()
  var remoteProfileLookupGeneration = 0
  var pendingIncomingMessages: [PendingIncomingMessage] = []
  var isDrainingPendingIncomingMessages = false
  var memberIntervalCache: [String: [SessionMemberIntervalEntity]] = [:]
  var memberIntervalCacheLegacy: [String: SessionMemberEntity?] = [:]
  var isBooting = false
  var isRetryingIdentityLoad = false
  var lastRegisteredPushDeviceSignature: String?
  var lastArchivedConversationSyncSignature: String?
  var suppressUnreadDuringHistoricalRestore = false
  var didEvalHistoricalUnreadPolicy = false

  @Published var composeError: String?
  @Published var pendingSessionNavigationRequest: SessionNavigationRequest?
  @Published var hasIdentity = false
  @Published var didFinishBoot = false
  @Published var bootStatusMessage = "loading account…"
  @Published var configuredRelays: [RelayEntity] = []
  @Published var pendingCreatedAccountNsec: String?
  @Published var currentProfileName: String?
  @Published var remoteProfilesByPubkey: [String: KnownProfileSnapshot] = [:]
  @Published var profileNameErrorMessage: String?

  var shouldShowOnboarding: Bool {
    !hasIdentity || pendingCreatedAccountNsec != nil
  }

  // MARK: - Initialization

  init(
    modelContext: ModelContext,
    relaySettingsUserDefaults: UserDefaults = .standard,
    testingOverrides: TestingOverrides = .init()
  ) {
    self.modelContext = modelContext
    self.testingOverrides = testingOverrides
    self.identityService = IdentityService()
    self.nostrService = NostrDMService()
    self.contactStore = ContactStore(modelContext: modelContext)
    self.relayStore = RelayStore(
      modelContext: modelContext,
      userDefaults: relaySettingsUserDefaults
    )
    self.messageStore = SessionMessageStore(modelContext: modelContext)
    self.accountStateStore = AccountStateStore(modelContext: modelContext)
  }

}
