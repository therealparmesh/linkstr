import Foundation
import NostrSDK
import SwiftData

#if canImport(UIKit)
  import UIKit
#endif

private enum RelayMutationDefaults {
  static let timeoutSeconds: TimeInterval = 12
  static let pollIntervalSeconds: TimeInterval = 0.35
}

private enum AppSessionTimingDefaults {
  static let remoteProfileLookupRetryNanoseconds: UInt64 = 3_000_000_000
  static let passiveOfflineToastGraceInterval: TimeInterval = 1.25
  static let relayDisconnectGraceInterval: TimeInterval = 1.25
  static let identityRetryDelayNanoseconds: UInt64 = 250_000_000
}

private enum IdentityLoadRetryDefaults {
  static let bootAttempts = 2
  static let protectedDataUnavailableBootAttempts = 6
  static let activeAttempts = 2
  static let protectedDataAttempts = 4
}

@MainActor
final class AppSession: ObservableObject {
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

  private struct RelayRuntimeStatus {
    var status: RelayHealthStatus
    var message: String?
    var updatedAt: Date
  }

  private struct PendingMetadataRefresh {
    let storageID: String
  }

  private struct PendingIncomingMessage {
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

  private enum IncomingPersistenceOutcome {
    case applied
    case ignored
    case pending
  }

  private enum InboundSessionResolution {
    case ready(SessionEntity)
    case pending
    case ignored
  }

  private struct RootPostDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let recipientPubkeys: [String]
    let normalizedURL: String
  }

  private struct ReactionDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let recipientPubkeys: [String]
  }

  private struct RootDeletionDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let recipientPubkeys: [String]
    let rootID: String
    let publishedTransportEventIDs: [String]
  }

  private struct SessionDeletionDraft {
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
    var skipDefaultRelaySetup = false
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

  private enum MutationPreparationError: Error {
    case relayBlocked
  }

  private struct LocalAccountCleanupError: LocalizedError {
    let failures: [String]

    var errorDescription: String? {
      guard !failures.isEmpty else { return nil }
      if failures.count == 1 {
        return failures[0]
      }
      return "local cleanup did not fully complete: \(failures.joined(separator: " "))"
    }
  }

  let identityService: IdentityService
  let modelContext: ModelContext
  private let contactStore: ContactStore
  private let relayStore: RelayStore
  private let messageStore: SessionMessageStore
  private let accountStateStore: AccountStateStore
  private let testingOverrides: TestingOverrides
  private var nostrService: NostrDMService
  private let noEnabledRelaysMessage =
    "no relays are enabled. enable at least one relay in settings."
  private let relayOfflineMessage = "you're offline. waiting for a relay connection."
  private let relayReadOnlyMessage =
    "connected relays are read-only. add a writable relay to send."
  private let relaySendTimeoutMessage = "couldn't reconnect to relays in time. try again."
  private var hasShownOfflineToastForCurrentOutage = false
  private var isForeground = false
  private var pendingMetadataRefreshes: [PendingMetadataRefresh] = []
  private var pendingMetadataRefreshHead = 0
  private var enqueuedMetadataStorageIDs = Set<String>()
  private var isProcessingMetadataQueue = false
  private var activeMetadataRefreshStorageID: String?
  private var metadataRefreshQueueGeneration = 0
  @Published private var relayRuntimeStatusByURL: [String: RelayRuntimeStatus] = [:]
  private var pendingOfflineToastTask: Task<Void, Never>?
  private var nostrStartupTask: Task<Void, Never>?
  private var hasObservedHealthyRelayInCurrentForeground = false
  private var suppressedComposeErrorPresentationCount = 0
  private var nostrStartupGeneration = 0
  private var passiveOfflineToastGraceUntil: Date?
  private var latestAppliedFollowListCreatedAt: Date?
  private var latestAppliedFollowListEventID: String?
  private var latestAppliedProfileMetadataCreatedAt: Date?
  private var latestAppliedProfileMetadataEventID: String?
  private var currentProfileMetadataContent: String?
  private var inFlightRemoteProfilePubkeys = Set<String>()
  private var pendingRemoteProfilePubkeys = Set<String>()
  private var pendingIncomingMessages: [PendingIncomingMessage] = []
  private var isDrainingPendingIncomingMessages = false
  private var memberIntervalCache: [String: [SessionMemberIntervalEntity]] = [:]
  private var memberIntervalCacheLegacy: [String: SessionMemberEntity?] = [:]
  private var isBooting = false
  private var isRetryingIdentityLoad = false
  private var lastRegisteredPushDeviceSignature: String?
  private var lastArchivedConversationSyncSignature: String?
  private var shouldSuppressUnreadDuringInitialHistoricalRestore = false
  private var hasEvaluatedInitialHistoricalUnreadPolicy = false

  @Published var composeError: String?
  @Published var pendingSessionNavigationID: String?
  @Published private(set) var hasIdentity = false
  @Published private(set) var didFinishBoot = false
  @Published private(set) var bootStatusMessage = "loading account…"
  @Published private(set) var pendingCreatedAccountNsec: String?
  @Published private(set) var currentProfileName: String?
  @Published private(set) var remoteProfilesByPubkey: [String: KnownProfileSnapshot] = [:]
  @Published private(set) var profileNameErrorMessage: String?

  var shouldShowOnboarding: Bool {
    !hasIdentity || pendingCreatedAccountNsec != nil
  }

  init(
    modelContext: ModelContext,
    testingOverrides: TestingOverrides = .init()
  ) {
    self.modelContext = modelContext
    self.testingOverrides = testingOverrides
    self.identityService = IdentityService()
    self.nostrService = NostrDMService()
    self.contactStore = ContactStore(modelContext: modelContext)
    self.relayStore = RelayStore(modelContext: modelContext)
    self.messageStore = SessionMessageStore(modelContext: modelContext)
    self.accountStateStore = AccountStateStore(modelContext: modelContext)
  }

  func boot() async {
    guard !isBooting, !didFinishBoot else { return }
    isBooting = true
    didFinishBoot = false
    bootStatusMessage = "loading account…"
    defer {
      isBooting = false
    }

    await retryIdentityLoadIfNeeded(
      maxAttempts: bootIdentityRetryAttemptCount,
      retryDelayNanoseconds: configuredIdentityRetryDelayNanoseconds
    )
    if !isRunningTests && !isEnvironmentFlagEnabled("LINKSTR_SKIP_NOTIFICATION_PROMPT") {
      PushNotificationService.shared.requestAuthorizationIfNeeded()
    }

    #if targetEnvironment(simulator)
      if isEnvironmentFlagEnabled("LINKSTR_SIM_BOOTSTRAP") {
        bootStatusMessage = "preparing simulator account…"
        bootstrapSimulatorIfNeeded()
        refreshIdentityState()
      }
    #endif

    do {
      bootStatusMessage = "preparing local data…"
      bootStatusMessage = "connecting relays…"
      if testingOverrides.skipDefaultRelaySetup {
        relayRuntimeStatusByURL.removeAll()
      } else {
        try relayStore.ensureDefaultRelays()
        pruneRuntimeRelayStatusCache()
      }
    } catch {
      composeError = error.localizedDescription
    }
    bootStatusMessage = "starting session…"
    didFinishBoot = true
    beginForegroundCycle()
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
  }

  func handleAppDidBecomeActive() {
    beginForegroundCycle()
    if !isRunningTests && !isEnvironmentFlagEnabled("LINKSTR_SKIP_NOTIFICATION_PROMPT") {
      PushNotificationService.shared.refreshRegistrationIfAuthorized()
    }
    guard didFinishBoot else { return }
    if identityService.keypair != nil {
      // Foreground re-entry is the safest cheap retry point for push registration and archive
      // sync, especially after transient network failures that did not change local signatures.
      schedulePushStateSync()
    }
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
  }

  func handleAppDidLeaveForeground() {
    let relayURLs = enabledRelayURLsSnapshot()
    isForeground = false
    hasObservedHealthyRelayInCurrentForeground = false
    passiveOfflineToastGraceUntil = nil
    cancelPendingOfflineToastIfNeeded()
    cancelPendingNostrStartupIfNeeded()
    stopRelayRuntime()
    primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
  }

  func handleProtectedDataDidBecomeAvailable() {
    guard didFinishBoot, isForeground else { return }
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.protectedDataAttempts)
  }

  func handlePushDeviceTokenDidChange() {
    schedulePushStateSync()
  }

  private func report(error: Error) {
    composeError = error.localizedDescription
  }

  var shouldPresentComposeErrorToast: Bool {
    suppressedComposeErrorPresentationCount == 0
  }

  func performFormMutation(_ operation: () async -> Bool) async -> FormMutationResult {
    suppressedComposeErrorPresentationCount += 1
    defer { suppressedComposeErrorPresentationCount -= 1 }

    let didSucceed = await operation()
    let errorMessage = didSucceed ? nil : takeComposeError()
    return FormMutationResult(didSucceed: didSucceed, errorMessage: errorMessage)
  }

  private func takeComposeError() -> String? {
    let message = composeError?.trimmingCharacters(in: .whitespacesAndNewlines)
    composeError = nil
    guard let message, !message.isEmpty else { return nil }
    return message
  }

  func relayConnectivityState(for enabledRelays: [RelayEntity]) -> RelayConnectivityState {
    guard !enabledRelays.isEmpty else { return .noEnabledRelays }

    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .connected }) {
      return .online
    }
    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .connecting }) {
      return .connecting
    }
    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .readOnly }) {
      return .readOnly
    }
    return .offline
  }

  private func clearOfflineToastIfPresent() {
    if composeError == relayOfflineMessage {
      composeError = nil
    }
  }

  private func cancelPendingOfflineToastIfNeeded() {
    pendingOfflineToastTask?.cancel()
    pendingOfflineToastTask = nil
  }

  private func cancelPendingNostrStartupIfNeeded() {
    nostrStartupGeneration += 1
    nostrStartupTask?.cancel()
    nostrStartupTask = nil
  }

  private func showOfflineToastForCurrentOutageIfNeeded() {
    guard hasObservedHealthyRelayInCurrentForeground else { return }
    guard !hasShownOfflineToastForCurrentOutage else { return }
    let now = Date.now
    if let passiveOfflineToastGraceUntil, now < passiveOfflineToastGraceUntil {
      scheduleOfflineToastReevaluation(at: passiveOfflineToastGraceUntil)
      return
    }
    cancelPendingOfflineToastIfNeeded()
    composeError = relayOfflineMessage
    hasShownOfflineToastForCurrentOutage = true
  }

  private func scheduleOfflineToastReevaluation(at deadline: Date) {
    guard pendingOfflineToastTask == nil else { return }
    let delay = max(0, deadline.timeIntervalSinceNow)
    pendingOfflineToastTask = Task { [weak self] in
      if delay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        defer { self.pendingOfflineToastTask = nil }
        guard self.isForeground else { return }
        try? self.refreshRelayConnectivityAlert()
      }
    }
  }

  private func clearRelaySendBlockingErrorIfPresent() {
    if composeError == relayOfflineMessage
      || composeError == noEnabledRelaysMessage
      || composeError == relayReadOnlyMessage
    {
      composeError = nil
    }
  }

  func relayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    if relay.isEnabled == false {
      return .disconnected
    }
    return effectiveRelayStatus(for: relay)
  }

  func relayErrorMessage(for relay: RelayEntity) -> String? {
    guard relay.isEnabled else { return nil }
    let trimmedRuntime =
      relayRuntimeStatusByURL[relay.url]?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    return trimmedRuntime.isEmpty ? nil : trimmedRuntime
  }

  func connectedRelayCount(for relays: [RelayEntity]) -> Int {
    relays.count { relay in
      relay.isEnabled
        && (relayStatus(for: relay) == .connected || relayStatus(for: relay) == .readOnly)
    }
  }

  func canManageSession(for session: SessionEntity) -> Bool {
    guard let myPubkey = identityService.pubkeyHex else { return false }
    return session.createdByPubkey == myPubkey
  }

  func isCurrentUserActiveMember(of session: SessionEntity, at timestamp: Date = .now) -> Bool {
    isCurrentUserActiveMember(
      sessionID: session.sessionID,
      ownerPubkey: session.ownerPubkey,
      at: timestamp
    )
  }

  func isCurrentUserActiveMember(
    sessionID: String,
    ownerPubkey: String,
    at timestamp: Date = .now
  ) -> Bool {
    guard let myPubkey = identityService.pubkeyHex else { return false }
    do {
      return try messageStore.isMemberActive(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        memberPubkey: myPubkey,
        at: timestamp
      )
    } catch {
      return false
    }
  }

  func clearProfileNameError() {
    profileNameErrorMessage = nil
  }

  func resolvedIdentity(for contact: ContactEntity) -> LinkstrResolvedIdentity {
    LinkstrResolvedIdentity(
      localAlias: contact.localAlias,
      chosenName: preferredChosenName(for: contact),
      pubkeyHex: contact.targetPubkey
    )
  }

  func resolvedIdentity(for pubkeyHex: String, contacts: [ContactEntity]) -> LinkstrResolvedIdentity
  {
    let normalizedPubkey = NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
    if let contact = contacts.first(where: { $0.targetPubkey == normalizedPubkey }) {
      return resolvedIdentity(for: contact)
    }
    return LinkstrResolvedIdentity(
      localAlias: nil,
      chosenName: remoteProfilesByPubkey[normalizedPubkey]?.chosenName,
      pubkeyHex: normalizedPubkey
    )
  }

  func displayName(for pubkeyHex: String, contacts: [ContactEntity]) -> String {
    resolvedIdentity(for: pubkeyHex, contacts: contacts).displayName
  }

  func searchableNames(for contact: ContactEntity) -> [String] {
    var names: [String] = []
    if let localAlias = contact.localAlias {
      names.append(localAlias)
    }
    if let chosenName = preferredChosenName(for: contact),
      names.contains(where: { $0.localizedCaseInsensitiveCompare(chosenName) == .orderedSame })
        == false
    {
      names.append(chosenName)
    }
    return names
  }

  private func effectiveRelayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    relayRuntimeStatusByURL[relay.url]?.status ?? .disconnected
  }

  private func updateRuntimeRelayStatus(
    relayURL: String,
    status: RelayHealthStatus,
    message: String?
  ) {
    if status == .connected || status == .readOnly {
      hasObservedHealthyRelayInCurrentForeground = true
      drainPendingIncomingMessagesIfNeeded()
      retryPendingRemoteProfileRequestsIfNeeded()
    }

    let now = Date()
    let normalizedMessage = normalizedRelayStatusMessage(message)
    if let existing = relayRuntimeStatusByURL[relayURL],
      existing.status == .connected || existing.status == .readOnly,
      status == .disconnected,
      normalizedMessage == nil,
      now.timeIntervalSince(existing.updatedAt)
        < AppSessionTimingDefaults.relayDisconnectGraceInterval
    {
      // Keep healthy status briefly while relay pool restarts to avoid flicker.
      return
    }

    if let existing = relayRuntimeStatusByURL[relayURL],
      existing.status == status,
      existing.message == normalizedMessage
    {
      relayRuntimeStatusByURL[relayURL]?.updatedAt = now
      return
    }

    relayRuntimeStatusByURL[relayURL] = RelayRuntimeStatus(
      status: status,
      message: normalizedMessage,
      updatedAt: now
    )
  }

  private var bootIdentityRetryAttemptCount: Int {
    isProtectedDataCurrentlyAvailable
      ? IdentityLoadRetryDefaults.bootAttempts
      : IdentityLoadRetryDefaults.protectedDataUnavailableBootAttempts
  }

  private var configuredIdentityRetryDelayNanoseconds: UInt64 {
    testingOverrides.identityRetryDelayNanoseconds
      ?? AppSessionTimingDefaults.identityRetryDelayNanoseconds
  }

  private var configuredRemoteProfileLookupRetryNanoseconds: UInt64 {
    testingOverrides.remoteProfileLookupRetryNanoseconds
      ?? AppSessionTimingDefaults.remoteProfileLookupRetryNanoseconds
  }

  private var isRunningTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  private var isProtectedDataCurrentlyAvailable: Bool {
    #if canImport(UIKit)
      UIApplication.shared.isProtectedDataAvailable
    #else
      true
    #endif
  }

  private func loadIdentityForCurrentProcess() -> IdentityService.LoadResult {
    if let loadIdentityOverride = testingOverrides.loadIdentity {
      return loadIdentityOverride(identityService)
    }
    return identityService.loadIdentity()
  }

  private func retryIdentityLoadIfNeeded(
    maxAttempts: Int,
    retryDelayNanoseconds: UInt64
  ) async {
    guard hasIdentity == false else { return }
    guard !isRetryingIdentityLoad else { return }

    isRetryingIdentityLoad = true
    defer { isRetryingIdentityLoad = false }

    let attemptCount = max(1, maxAttempts)
    for attempt in 1...attemptCount {
      let loadResult = loadIdentityForCurrentProcess()
      refreshIdentityState()
      guard hasIdentity == false else { return }
      guard attempt < attemptCount else { return }

      switch loadResult {
      case .loaded:
        return
      case .missing, .failed:
        break
      }

      try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
    }
  }

  private func normalizedRelayStatusMessage(_ message: String?) -> String? {
    guard let message else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func enabledRelayURLsSnapshot() -> [String] {
    (try? relayStore.fetchRelays().filter(\.isEnabled).map(\.url)) ?? []
  }

  private func clearRelayRuntimeTracking() {
    relayRuntimeStatusByURL.removeAll()
  }

  private func replaceNostrService() {
    nostrService.stop()
    nostrService = NostrDMService()
  }

  private func primeRelayRuntimeStatusForFreshStart(relayURLs: [String]) {
    guard !relayURLs.isEmpty else { return }
    let now = Date()
    relayRuntimeStatusByURL = Dictionary(
      uniqueKeysWithValues: relayURLs.map {
        (
          $0,
          RelayRuntimeStatus(
            status: .disconnected,
            message: nil,
            updatedAt: now
          )
        )
      }
    )
  }

  private func stopRelayRuntime() {
    clearRelayRuntimeTracking()
    replaceNostrService()
  }

  private func beginForegroundCycle() {
    isForeground = true
    hasObservedHealthyRelayInCurrentForeground = false
    hasShownOfflineToastForCurrentOutage = false
    clearOfflineToastIfPresent()
    passiveOfflineToastGraceUntil = Date.now.addingTimeInterval(
      testingOverrides.passiveOfflineToastGraceInterval
        ?? AppSessionTimingDefaults.passiveOfflineToastGraceInterval
    )
    cancelPendingOfflineToastIfNeeded()
    cancelPendingNostrStartupIfNeeded()
  }

  private func scheduleNostrStartup(maxAttempts: Int) {
    cancelPendingNostrStartupIfNeeded()
    guard didFinishBoot, isForeground else { return }

    nostrStartupGeneration += 1
    let generation = nostrStartupGeneration
    nostrStartupTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.nostrStartupGeneration == generation {
          self.nostrStartupTask = nil
        }
      }
      await self.retryIdentityLoadIfNeeded(
        maxAttempts: maxAttempts,
        retryDelayNanoseconds: self.configuredIdentityRetryDelayNanoseconds
      )
      guard !Task.isCancelled else { return }
      guard self.isForeground else { return }
      guard self.identityService.keypair != nil else { return }
      self.startNostrIfPossible(forceRestart: true)
    }
  }

  private func pruneRuntimeRelayStatusCache() {
    let relays = (try? relayStore.fetchRelays()) ?? []
    let enabledURLs = Set(relays.filter(\.isEnabled).map(\.url))
    relayRuntimeStatusByURL = relayRuntimeStatusByURL.filter { enabledURLs.contains($0.key) }
  }

  private func refreshRelayConnectivityAlert() throws {
    let enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    switch relayConnectivityState(for: enabledRelays) {
    case .online, .readOnly:
      cancelPendingOfflineToastIfNeeded()
      clearOfflineToastIfPresent()
    case .connecting:
      cancelPendingOfflineToastIfNeeded()
      return
    case .offline:
      showOfflineToastForCurrentOutageIfNeeded()
    case .noEnabledRelays:
      cancelPendingOfflineToastIfNeeded()
      return
    }
  }

  private enum RelaySendWaitState {
    case ready
    case blocked(message: String)
    case waitingForConnection
  }

  private func relaySendWaitState() -> RelaySendWaitState {
    if shouldDisableNostrStartupForCurrentProcess() {
      return .ready
    }

    let enabledRelays: [RelayEntity]
    do {
      enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    } catch {
      return .blocked(message: error.localizedDescription)
    }

    switch relayConnectivityState(for: enabledRelays) {
    case .noEnabledRelays:
      if let hasConnectedRelaysOverride = testingOverrides.hasConnectedRelays,
        hasConnectedRelaysOverride()
      {
        return .ready
      }
      return .blocked(message: noEnabledRelaysMessage)
    case .readOnly:
      return .blocked(message: relayReadOnlyMessage)
    case .online:
      return .ready
    case .connecting, .offline:
      if let hasConnectedRelaysOverride = testingOverrides.hasConnectedRelays,
        hasConnectedRelaysOverride()
      {
        return .ready
      }
      return .waitingForConnection
    }
  }

  private func awaitRelayReadyForSend(
    timeoutSeconds: TimeInterval,
    pollIntervalSeconds: TimeInterval
  ) async -> Bool {
    let timeout = max(0, timeoutSeconds)
    let pollInterval = max(0.05, pollIntervalSeconds)
    let deadline = Date.now.addingTimeInterval(timeout)

    while true {
      switch relaySendWaitState() {
      case .ready:
        clearRelaySendBlockingErrorIfPresent()
        return true
      case .blocked(let message):
        composeError = message
        hasShownOfflineToastForCurrentOutage = false
        return false
      case .waitingForConnection:
        if Date.now >= deadline {
          composeError = relaySendTimeoutMessage
          hasShownOfflineToastForCurrentOutage = false
          return false
        }

        if composeError == relayOfflineMessage {
          composeError = nil
        }
        startNostrIfPossible()

        let sleepNanoseconds = UInt64(pollInterval * 1_000_000_000)
        try? await Task.sleep(nanoseconds: sleepNanoseconds)
      }
    }
  }

  private func makeLocalEventID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  private func isEnvironmentFlagEnabled(_ key: String) -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env[key] == "1"
  }

  private func shouldDisableNostrStartupForCurrentProcess() -> Bool {
    if let disableNostrStartupOverride = testingOverrides.disableNostrStartup {
      return disableNostrStartupOverride
    }

    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return false }
    return !isEnvironmentFlagEnabled("LINKSTR_ENABLE_NOSTR_IN_TESTS")
  }

  private func isRelayPublicationEnabledForCurrentProcess() -> Bool {
    !shouldDisableNostrStartupForCurrentProcess()
  }

  private func prepareRelayMutationIfNeeded(
    timeoutSeconds: TimeInterval,
    pollIntervalSeconds: TimeInterval
  ) async throws {
    guard isRelayPublicationEnabledForCurrentProcess() else { return }
    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      throw MutationPreparationError.relayBlocked
    }
  }

  private func shouldFetchMetadataForCurrentProcess() -> Bool {
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return true }
    return isEnvironmentFlagEnabled("LINKSTR_ENABLE_METADATA_IN_TESTS")
  }

  private func shouldFetchLinkMetadataForCurrentProcess() -> Bool {
    if testingOverrides.fetchLinkPreview != nil { return true }
    return shouldFetchMetadataForCurrentProcess()
  }

  private func resetPushSyncState() {
    lastRegisteredPushDeviceSignature = nil
    lastArchivedConversationSyncSignature = nil
  }

  private func shouldManagePushStateForCurrentProcess() -> Bool {
    if testingOverrides.registerPushDevice != nil
      || testingOverrides.syncArchivedConversationIDs != nil
      || testingOverrides.enqueuePushNotification != nil
      || testingOverrides.unregisterPushDevice != nil
    {
      return true
    }
    if isRunningTests {
      return false
    }
    return PushAPIClient.shared.isConfigured
  }

  private func schedulePushStateSync() {
    guard shouldManagePushStateForCurrentProcess() else { return }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      resetPushSyncState()
      return
    }

    let deviceToken = PushNotificationService.shared.deviceTokenHex
    let apnsEnvironment = PushNotificationService.shared.apnsEnvironment
    let archivedConversationIDs =
      (try? messageStore.archivedConversationIDs(ownerPubkey: ownerPubkey)) ?? []
    let deviceSignature =
      deviceToken.map { "\(ownerPubkey)|\($0)|\(apnsEnvironment)" }
    let archiveSignature =
      "\(ownerPubkey)|\(archivedConversationIDs.sorted().joined(separator: ","))"

    Task { @MainActor in
      if let deviceToken, lastRegisteredPushDeviceSignature != deviceSignature {
        do {
          try await registerPushDevice(
            PushDeviceRegistration(
              deviceToken: deviceToken,
              apnsEnvironment: apnsEnvironment
            ),
            signedBy: keypair
          )
          lastRegisteredPushDeviceSignature = deviceSignature
        } catch {
          NSLog("Push device registration failed: \(error.localizedDescription)")
        }
      }

      guard lastArchivedConversationSyncSignature != archiveSignature else { return }
      do {
        try await syncArchivedConversationIDs(archivedConversationIDs, signedBy: keypair)
        lastArchivedConversationSyncSignature = archiveSignature
      } catch {
        NSLog("Push archive sync failed: \(error.localizedDescription)")
      }
    }
  }

  private func schedulePushDeviceUnregistration(deviceToken: String?, keypair: Keypair?) {
    guard shouldManagePushStateForCurrentProcess() else { return }
    guard let deviceToken, let keypair else { return }
    Task { @MainActor in
      do {
        try await unregisterPushDevice(deviceToken: deviceToken, signedBy: keypair)
      } catch {
        NSLog("Push device unregistration failed: \(error.localizedDescription)")
      }
    }
  }

  private func schedulePushEnqueue(_ request: PushEnqueueRequest) {
    guard shouldManagePushStateForCurrentProcess() else { return }
    guard let keypair = identityService.keypair else { return }
    Task { @MainActor in
      do {
        try await enqueuePushNotification(request, signedBy: keypair)
      } catch {
        NSLog("Push enqueue failed: \(error.localizedDescription)")
      }
    }
  }

  private func registerPushDevice(_ registration: PushDeviceRegistration, signedBy keypair: Keypair)
    async throws
  {
    if let registerPushDeviceOverride = testingOverrides.registerPushDevice {
      try await registerPushDeviceOverride(registration)
      return
    }
    try await PushAPIClient.shared.registerDevice(registration, signedBy: keypair)
  }

  private func unregisterPushDevice(deviceToken: String, signedBy keypair: Keypair) async throws {
    if let unregisterPushDeviceOverride = testingOverrides.unregisterPushDevice {
      try await unregisterPushDeviceOverride(deviceToken)
      return
    }
    try await PushAPIClient.shared.unregisterDevice(deviceToken: deviceToken, signedBy: keypair)
  }

  private func syncArchivedConversationIDs(_ conversationIDs: [String], signedBy keypair: Keypair)
    async throws
  {
    if let syncArchivedConversationIDsOverride = testingOverrides.syncArchivedConversationIDs {
      try await syncArchivedConversationIDsOverride(conversationIDs)
      return
    }
    try await PushAPIClient.shared.syncArchivedConversations(
      conversationIDs.sorted(),
      signedBy: keypair
    )
  }

  private func enqueuePushNotification(_ request: PushEnqueueRequest, signedBy keypair: Keypair)
    async throws
  {
    if let enqueuePushNotificationOverride = testingOverrides.enqueuePushNotification {
      try await enqueuePushNotificationOverride(request)
      return
    }
    try await PushAPIClient.shared.enqueuePush(request, signedBy: keypair)
  }

  func createAccount() {
    guard identityService.keypair == nil else {
      refreshIdentityState()
      return
    }

    do {
      try identityService.createNewIdentity()
      pendingCreatedAccountNsec = try identityService.revealNsec()
      refreshIdentityState()
      profileNameErrorMessage = nil
      composeError = nil
      scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
    } catch {
      pendingCreatedAccountNsec = nil
      composeError = error.localizedDescription
    }
  }

  func completePendingAccountCreation() {
    pendingCreatedAccountNsec = nil
    profileNameErrorMessage = nil
  }

  @discardableResult
  func completePendingAccountCreation(
    profileName: String?,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    let normalizedProfileName = NostrProfileMetadata.normalizedChosenName(profileName)
    guard normalizedProfileName != nil else {
      completePendingAccountCreation()
      return true
    }

    guard
      await updateOwnProfileName(
        normalizedProfileName,
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }

    completePendingAccountCreation()
    return true
  }

  func importNsec(_ nsec: String) {
    do {
      try identityService.importNsec(nsec)
      pendingCreatedAccountNsec = nil
      refreshIdentityState()
      profileNameErrorMessage = nil
      composeError = nil
      scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
    } catch {
      composeError = error.localizedDescription
    }
  }

  @discardableResult
  func updateOwnProfileName(
    _ profileName: String?,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      let message = "you're signed out. sign in to manage your profile."
      profileNameErrorMessage = message
      composeError = message
      return false
    }

    let normalizedProfileName: String?
    do {
      normalizedProfileName = try NostrProfileMetadata.validatedOwnChosenName(profileName)
    } catch {
      profileNameErrorMessage = error.localizedDescription
      composeError = error.localizedDescription
      return false
    }

    let metadataContent: String
    do {
      metadataContent = try NostrProfileMetadata.mergedContent(
        existingContent: currentProfileMetadataContent,
        chosenName: normalizedProfileName
      )
    } catch {
      profileNameErrorMessage = error.localizedDescription
      report(error: error)
      return false
    }

    let metadataEvent: NostrEvent
    do {
      metadataEvent = try NostrEvent.Builder<NostrEvent>(kind: .metadata)
        .content(metadataContent)
        .build(signedBy: keypair)
    } catch {
      profileNameErrorMessage = error.localizedDescription
      report(error: error)
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishEventAwaitingRelayAcceptance(metadataEvent)
      }
      persistOwnProfileMetadataState(
        ownerPubkey: ownerPubkey,
        chosenName: normalizedProfileName,
        content: metadataContent,
        createdAt: metadataEvent.createdDate,
        eventID: metadataEvent.id
      )
      profileNameErrorMessage = nil
      composeError = nil
      return true
    } catch MutationPreparationError.relayBlocked {
      profileNameErrorMessage = composeError
      return false
    } catch {
      profileNameErrorMessage = error.localizedDescription
      report(error: error)
      return false
    }
  }

  func logOut(clearLocalData: Bool) {
    let ownerPubkey = identityService.pubkeyHex
    let keypair = identityService.keypair
    let deviceToken = PushNotificationService.shared.deviceTokenHex
    schedulePushDeviceUnregistration(deviceToken: deviceToken, keypair: keypair)
    resetRuntimeSessionState()

    do {
      try identityService.clearIdentity()
    } catch {
      composeError = error.localizedDescription
      return
    }
    handleIdentityCleared()

    if let ownerPubkey, clearLocalData {
      do {
        try clearLocalAccountData(ownerPubkey: ownerPubkey)
      } catch {
        composeError =
          "signed out, but some local data could not be removed. \(error.localizedDescription)"
        return
      }
    }

    composeError = nil
  }

  @discardableResult
  func deleteAccountAwaitingRelay(
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this account."
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishFollowListAwaitingRelayAcceptance(followedPubkeyHexes: [])
        _ = try await publishEventAwaitingRelayAcceptance(
          makeVanishEvent(
            relayURLs: try relayStore.fetchRelays().filter(\.isEnabled).map(\.url),
            signedBy: keypair
          )
        )
      }
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    let deviceToken = PushNotificationService.shared.deviceTokenHex
    schedulePushDeviceUnregistration(deviceToken: deviceToken, keypair: keypair)
    resetRuntimeSessionState()

    do {
      try identityService.clearIdentity()
    } catch {
      composeError = error.localizedDescription
      return false
    }
    handleIdentityCleared()
    do {
      try clearLocalAccountData(ownerPubkey: ownerPubkey)
    } catch {
      composeError =
        "account deletion finished, but some local data could not be removed. \(error.localizedDescription)"
      return false
    }
    composeError = nil
    return true
  }

  private func refreshIdentityState() {
    hasIdentity = identityService.keypair != nil
    guard let ownerPubkey = identityService.pubkeyHex else {
      resetPushSyncState()
      resetFollowListStateInMemory()
      resetRemoteProfileStateInMemory()
      resetProfileMetadataStateInMemory()
      return
    }
    if testingOverrides.skipPersistedFollowListStateLoad {
      resetFollowListStateInMemory()
      resetRemoteProfileStateInMemory()
      resetProfileMetadataStateInMemory()
      return
    }
    loadPersistedFollowListState(ownerPubkey: ownerPubkey)
    resetRemoteProfileStateInMemory()
    loadPersistedProfileMetadataState(ownerPubkey: ownerPubkey)
    schedulePushStateSync()
  }

  private func invalidateMemberIntervalCache() {
    memberIntervalCache.removeAll()
    memberIntervalCacheLegacy.removeAll()
  }

  private func invalidateMemberIntervalCache(sessionID: String) {
    let keysToRemove = memberIntervalCache.keys.filter { $0.hasPrefix("\(sessionID):") }
    for key in keysToRemove { memberIntervalCache.removeValue(forKey: key) }
    let legacyKeysToRemove = memberIntervalCacheLegacy.keys.filter {
      $0.hasPrefix("\(sessionID):")
    }
    for key in legacyKeysToRemove { memberIntervalCacheLegacy.removeValue(forKey: key) }
  }

  private func cachedMemberIntervals(
    sessionID: String,
    ownerPubkey: String,
    memberPubkeyHash: String
  ) throws -> [SessionMemberIntervalEntity] {
    let cacheKey = "\(sessionID):\(memberPubkeyHash)"
    if let cached = memberIntervalCache[cacheKey] {
      return cached
    }
    let intervals = try messageStore.memberIntervals(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      memberPubkeyHash: memberPubkeyHash
    )
    memberIntervalCache[cacheKey] = intervals
    return intervals
  }

  private func cachedLegacyMember(
    sessionID: String,
    ownerPubkey: String,
    memberPubkeyHash: String
  ) throws -> SessionMemberEntity? {
    let cacheKey = "\(sessionID):\(memberPubkeyHash)"
    if let cached = memberIntervalCacheLegacy[cacheKey] {
      return cached
    }
    let allMembers = try messageStore.members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: false
    )
    // Cache every member for this session in one fetch.
    for member in allMembers {
      let memberKey = "\(sessionID):\(member.memberPubkeyHash)"
      memberIntervalCacheLegacy[memberKey] = member
    }
    // Also cache nil for the requested key if not found.
    if memberIntervalCacheLegacy[cacheKey] == nil {
      memberIntervalCacheLegacy[cacheKey] = .some(nil)
    }
    return memberIntervalCacheLegacy[cacheKey] ?? nil
  }

  private func cachedIsMemberActive(
    sessionID: String,
    ownerPubkey: String,
    memberPubkey: String,
    at timestamp: Date
  ) throws -> Bool {
    guard let normalizedMemberPubkey = NostrValueNormalizer.normalizedPubkeyHex(memberPubkey) else {
      throw NostrServiceError.invalidPubkey
    }
    let memberHash = LocalDataCrypto.shared.digestHex(normalizedMemberPubkey)
    let intervals = try cachedMemberIntervals(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      memberPubkeyHash: memberHash
    )
    if let matchingInterval = intervals.last(where: { $0.contains(timestamp) }) {
      return matchingInterval.memberPubkey == normalizedMemberPubkey
    }

    // Backward-compat fallback for legacy rows created before interval tracking.
    guard
      let legacyMember = try cachedLegacyMember(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        memberPubkeyHash: memberHash
      )
    else {
      return false
    }
    guard legacyMember.updatedAt <= timestamp else { return false }
    return legacyMember.isActive
  }

  private func resetRuntimeSessionState() {
    let relayURLs = enabledRelayURLsSnapshot()
    stopRelayRuntime()
    primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
    cancelPendingOfflineToastIfNeeded()
    cancelPendingNostrStartupIfNeeded()
    pendingIncomingMessages.removeAll()
    isDrainingPendingIncomingMessages = false
    invalidateMemberIntervalCache()
    resetInitialHistoricalUnreadPolicy()
    pendingMetadataRefreshes.removeAll()
    pendingMetadataRefreshHead = 0
    enqueuedMetadataStorageIDs.removeAll()
    isProcessingMetadataQueue = false
    activeMetadataRefreshStorageID = nil
    metadataRefreshQueueGeneration = 0
    passiveOfflineToastGraceUntil = nil
    pendingSessionNavigationID = nil
    pendingCreatedAccountNsec = nil
  }

  private func handleIdentityCleared() {
    resetPushSyncState()
    refreshIdentityState()
    resetFollowListStateInMemory()
    resetRemoteProfileStateInMemory()
    resetProfileMetadataStateInMemory()
    profileNameErrorMessage = nil
  }

  private func clearLocalAccountData(ownerPubkey: String) throws {
    if let clearLocalAccountDataOverride = testingOverrides.clearLocalAccountData {
      try clearLocalAccountDataOverride(ownerPubkey)
      return
    }

    var failures: [String] = []

    do {
      try messageStore.clearAllSessionData(ownerPubkey: ownerPubkey)
      ThumbnailImageCache.shared.clear()
    } catch {
      failures.append("couldn't remove local sessions and posts.")
    }

    do {
      try contactStore.clearAllContacts(ownerPubkey: ownerPubkey)
    } catch {
      failures.append("couldn't remove local contacts.")
    }

    do {
      try LocalDataCrypto.shared.clearKey(ownerPubkey: ownerPubkey)
    } catch {
      failures.append(error.localizedDescription)
    }

    do {
      try accountStateStore.deleteAccountState(ownerPubkey: ownerPubkey)
    } catch {
      failures.append("couldn't remove local account state.")
    }

    if !failures.isEmpty {
      throw LocalAccountCleanupError(failures: failures)
    }
  }

  func startNostrIfPossible(forceRestart: Bool = false) {
    guard let keypair = identityService.keypair else { return }

    if forceRestart {
      stopRelayRuntime()
    }

    if shouldDisableNostrStartupForCurrentProcess() {
      // Keep local send paths available in tests without opening relay connections.
      if !forceRestart {
        clearRelayRuntimeTracking()
      }
      testingOverrides.onNostrStart?()
      return
    }

    if isRunningTests, testingOverrides.skipNostrNetworkStartup {
      if forceRestart {
        let relayURLs = enabledRelayURLsSnapshot()
        primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
      } else {
        clearRelayRuntimeTracking()
      }
      startNostrRuntime(
        keypair: keypair,
        relayURLs: [],
        onIncoming: { _ in },
        onRelayStatus: { _, _, _ in },
        onInitialBackfillComplete: { [weak self] in
          self?.finishInitialHistoricalRestore()
        }
      )
      return
    }

    let relayURLs: [String]
    do {
      relayURLs = try relayStore.fetchRelays().filter(\.isEnabled).map(\.url)
    } catch {
      report(error: error)
      return
    }

    if forceRestart {
      primeRelayRuntimeStatusForFreshStart(relayURLs: relayURLs)
    }
    if relayURLs.isEmpty {
      if !forceRestart {
        stopRelayRuntime()
      }
      composeError = noEnabledRelaysMessage
      hasShownOfflineToastForCurrentOutage = false
      return
    }
    if composeError == noEnabledRelaysMessage {
      composeError = nil
    }
    relayRuntimeStatusByURL = relayRuntimeStatusByURL.filter { relayURLs.contains($0.key) }

    startNostrRuntime(
      keypair: keypair,
      relayURLs: relayURLs,
      onIncoming: { [weak self] incoming in
        Task { @MainActor in
          self?.persistIncoming(incoming)
        }
      },
      onRelayStatus: { [weak self] relayURL, status, message in
        Task { @MainActor in
          guard let self else { return }
          guard self.isForeground else { return }
          self.updateRuntimeRelayStatus(
            relayURL: relayURL,
            status: status,
            message: message
          )
          try? self.refreshRelayConnectivityAlert()
        }
      },
      onInitialBackfillComplete: { [weak self] in
        self?.finishInitialHistoricalRestore()
      },
      onFollowList: { [weak self] followList in
        Task { @MainActor in
          self?.persistIncomingFollowList(followList)
        }
      },
      onProfileMetadata: { [weak self] profileMetadata in
        Task { @MainActor in
          self?.persistIncomingProfileMetadata(profileMetadata)
        }
      }
    )
  }

  private func startNostrRuntime(
    keypair: Keypair,
    relayURLs: [String],
    onIncoming: @escaping (ReceivedDirectMessage) -> Void,
    onRelayStatus: @escaping (String, RelayHealthStatus, String?) -> Void,
    onInitialBackfillComplete: (() -> Void)? = nil,
    onFollowList: ((ReceivedFollowList) -> Void)? = nil,
    onProfileMetadata: ((ReceivedProfileMetadata) -> Void)? = nil
  ) {
    testingOverrides.onNostrStart?()
    nostrService.start(
      keypair: keypair,
      relayURLs: relayURLs,
      onIncoming: onIncoming,
      onRelayStatus: onRelayStatus,
      onInitialBackfillComplete: onInitialBackfillComplete,
      onFollowList: onFollowList,
      onProfileMetadata: onProfileMetadata
    )
  }

  @discardableResult
  func createSessionAwaitingRelay(
    name: String,
    memberNPubs: [String],
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      composeError = "enter a session name."
      return false
    }

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to create sessions."
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    let members = normalizedMemberPubkeys(
      fromNPubs: memberNPubs,
      myPubkey: keypair.publicKey.hex
    )
    let sessionID = makeLocalEventID()
    let now = Date.now
    let timestamp = Int64(now.timeIntervalSince1970)
    let payload = LinkstrPayload(
      conversationID: sessionID,
      rootID: makeLocalEventID(),
      kind: .sessionCreate,
      url: nil,
      note: nil,
      timestamp: timestamp,
      sessionName: normalizedName,
      memberPubkeys: members
    )

    do {
      let membershipEventID: String
      if isRelayPublicationEnabledForCurrentProcess() {
        membershipEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: payload,
          recipientPubkeyHexes: members
        ).rumorEventID
      } else {
        membershipEventID = makeLocalEventID()
      }

      let updatedAt = now
      _ = try applySessionSnapshotLocally(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        createdByPubkey: keypair.publicKey.hex,
        sessionName: normalizedName,
        memberPubkeys: members,
        updatedAt: updatedAt,
        eventID: membershipEventID
      )
      pendingSessionNavigationID = sessionID
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func updateSessionMembersAwaitingRelay(
    session: SessionEntity,
    memberNPubs: [String],
    sessionName: String? = nil,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this session."
      return false
    }

    guard canManageSession(for: session) else {
      composeError = "only the session creator can manage this session."
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    let members = normalizedMemberPubkeys(
      fromNPubs: memberNPubs,
      myPubkey: keypair.publicKey.hex
    )
    let now = Date.now
    let timestamp = Int64(now.timeIntervalSince1970)
    let effectiveName = sessionName ?? session.name
    let payload = LinkstrPayload(
      conversationID: session.sessionID,
      rootID: makeLocalEventID(),
      kind: .sessionMembers,
      url: nil,
      note: nil,
      timestamp: timestamp,
      sessionName: effectiveName,
      memberPubkeys: members
    )

    do {
      let priorActiveMembers = try messageStore.members(
        sessionID: session.sessionID,
        ownerPubkey: ownerPubkey,
        activeOnly: true
      ).map(\.memberPubkey)
      let updateRecipients = mergedPubkeys(priorActiveMembers, members)

      let membershipEventID: String
      if isRelayPublicationEnabledForCurrentProcess() {
        membershipEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: payload,
          recipientPubkeyHexes: updateRecipients
        ).rumorEventID
      } else {
        membershipEventID = makeLocalEventID()
      }

      let updatedAt = now
      _ = try applySessionSnapshotLocally(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID,
        createdByPubkey: session.createdByPubkey,
        sessionName: effectiveName,
        memberPubkeys: members,
        updatedAt: updatedAt,
        eventID: membershipEventID,
        isArchived: session.isArchived
      )
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func createSessionPostAwaitingRelay(
    url: String,
    note: String?,
    session: SessionEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let draft = makeRootPostDraft(url: url, note: note, sessionID: session.sessionID) else {
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    if !isRelayPublicationEnabledForCurrentProcess() {
      return createPostLocally(draft)
    }
    return await createPostAwaitingRelayDelivery(draft)
  }

  @discardableResult
  private func createPostLocally(_ draft: RootPostDraft) -> Bool {
    do {
      // Test-only local send path when relay startup is disabled in-process.
      let eventID = makeLocalEventID()
      try persistSentRootPost(draft, receipt: localSendReceipt(withRumorEventID: eventID))
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func toggleReactionAwaitingRelay(
    emoji: String,
    post: SessionMessageEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let draft = makeReactionDraft(emoji: emoji, post: post) else {
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    do {
      let reactionEventID: String
      let shouldEnqueuePush: Bool
      if isRelayPublicationEnabledForCurrentProcess() {
        reactionEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: draft.payload,
          recipientPubkeyHexes: draft.recipientPubkeys
        ).rumorEventID
        shouldEnqueuePush = true
      } else {
        reactionEventID = makeLocalEventID()
        shouldEnqueuePush = false
      }
      try persistReactionState(draft, eventID: reactionEventID)
      if shouldEnqueuePush, draft.payload.reactionActive == true {
        schedulePushEnqueue(
          PushEnqueueRequest(
            notificationType: "new_emoji_reaction",
            eventID: reactionEventID,
            conversationID: draft.payload.conversationID,
            recipientPubkeys: draft.recipientPubkeys,
            emoji: draft.payload.emoji
          )
        )
      }
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func deletePostAwaitingRelay(
    _ post: SessionMessageEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let draft = makeRootDeletionDraft(post: post) else {
      return false
    }

    if !isRelayPublicationEnabledForCurrentProcess() {
      do {
        try persistRootDeletion(draft, eventID: makeLocalEventID())
        composeError = nil
        return true
      } catch {
        report(error: error)
        return false
      }
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    guard let keypair = identityService.keypair else {
      composeError = "you're signed out. sign in to manage this post."
      return false
    }

    do {
      let deletionRequestEventID: String?
      if draft.publishedTransportEventIDs.isEmpty {
        deletionRequestEventID = nil
      } else {
        deletionRequestEventID = try await publishEventAwaitingRelayAcceptance(
          makeRelayDeletionEvent(
            publishedTransportEventIDs: draft.publishedTransportEventIDs,
            reason: "linkstr post deletion request",
            signedBy: keypair
          )
        )
      }

      let deletionWatermarkEventID: String
      do {
        deletionWatermarkEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: draft.payload,
          recipientPubkeyHexes: draft.recipientPubkeys
        ).rumorEventID
      } catch {
        if let deletionRequestEventID {
          try persistRootDeletion(draft, eventID: deletionRequestEventID)
          composeError = "post deleted, but other members may keep seeing it until sync catches up."
          return true
        }
        throw error
      }

      try persistRootDeletion(draft, eventID: deletionWatermarkEventID)
      if deletionRequestEventID == nil {
        composeError =
          "post deleted, but relay deletion is unavailable for older copies of this post."
      } else {
        composeError = nil
      }
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func deleteSessionAwaitingRelay(
    _ session: SessionEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let draft = makeSessionDeletionDraft(session: session) else {
      return false
    }

    if !isRelayPublicationEnabledForCurrentProcess() {
      do {
        try persistSessionDeletion(draft, eventID: makeLocalEventID())
        composeError = nil
        return true
      } catch {
        report(error: error)
        return false
      }
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    guard let keypair = identityService.keypair else {
      composeError = "you're signed out. sign in to manage this session."
      return false
    }

    do {
      let deletionEventID = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      ).rumorEventID
      try persistSessionDeletion(draft, eventID: deletionEventID)

      guard !draft.publishedTransportEventIDs.isEmpty else {
        composeError =
          draft.hadStoredRootPosts
          ? "session deleted, but older relay copies of its posts may remain."
          : nil
        return true
      }

      do {
        _ = try await publishEventAwaitingRelayAcceptance(
          makeRelayDeletionEvent(
            publishedTransportEventIDs: draft.publishedTransportEventIDs,
            reason: "linkstr session deletion request",
            signedBy: keypair
          )
        )
        composeError = nil
      } catch {
        NSLog("Session relay deletion request failed: \(error.localizedDescription)")
        composeError = "session deleted, but older relay copies of its posts may remain."
      }
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func createPostAwaitingRelayDelivery(_ draft: RootPostDraft) async -> Bool {
    do {
      let receipt = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      )
      try persistSentRootPost(draft, receipt: receipt)
      schedulePushEnqueue(
        PushEnqueueRequest(
          notificationType: "new_post",
          eventID: receipt.rumorEventID,
          conversationID: draft.payload.conversationID,
          recipientPubkeys: draft.recipientPubkeys,
          emoji: nil
        )
      )
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func makeReactionDraft(emoji: String, post: SessionMessageEntity) -> ReactionDraft? {
    let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEmoji.isEmpty else {
      composeError = "pick an emoji reaction."
      return nil
    }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to react."
      return nil
    }

    guard
      let recipientPubkeys = resolveOutboundRecipients(
        sessionID: post.conversationID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else {
      return nil
    }

    let existingReactions =
      (try? messageStore.reactions(
        ownerPubkey: ownerPubkey,
        sessionID: post.conversationID
      )) ?? []
    let senderHash = LocalDataCrypto.shared.digestHex(keypair.publicKey.hex)
    let currentlyActive = existingReactions.contains { reaction in
      reaction.postID == post.rootID
        && reaction.emoji == normalizedEmoji
        && reaction.senderMatchesHash(senderHash)
        && reaction.isActive
    }
    let nextState = !currentlyActive
    let timestamp = Int64(Date.now.timeIntervalSince1970)

    return ReactionDraft(
      payload: LinkstrPayload(
        conversationID: post.conversationID,
        rootID: post.rootID,
        kind: .reaction,
        url: nil,
        note: nil,
        timestamp: timestamp,
        emoji: normalizedEmoji,
        reactionActive: nextState
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys
    )
  }

  private func makeRootDeletionDraft(post: SessionMessageEntity) -> RootDeletionDraft? {
    guard post.kind == .root else {
      composeError = "only root posts can be deleted."
      return nil
    }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this post."
      return nil
    }
    let senderHash = LocalDataCrypto.shared.digestHex(keypair.publicKey.hex)
    guard post.senderMatchesHash(senderHash) else {
      composeError = "you can only delete posts you sent."
      return nil
    }

    guard
      let recipientPubkeys = resolveDeletionRecipients(
        sessionID: post.conversationID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else {
      return nil
    }

    let timestamp = Int64(Date.now.timeIntervalSince1970)
    return RootDeletionDraft(
      payload: LinkstrPayload(
        conversationID: post.conversationID,
        rootID: post.rootID,
        kind: .rootDelete,
        url: nil,
        note: nil,
        timestamp: timestamp
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys,
      rootID: post.rootID,
      publishedTransportEventIDs: post.publishedTransportEventIDs
    )
  }

  private func makeSessionDeletionDraft(session: SessionEntity) -> SessionDeletionDraft? {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this session."
      return nil
    }
    guard canManageSession(for: session) else {
      composeError = "only the session creator can delete this session."
      return nil
    }

    guard
      let recipientPubkeys = resolveDeletionRecipients(
        sessionID: session.sessionID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else {
      return nil
    }

    let publishedTransportEventIDs: [String]
    let hadStoredRootPosts: Bool
    do {
      publishedTransportEventIDs = try messageStore.knownSessionTransportEventIDs(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID
      )
      hadStoredRootPosts = try messageStore.hasRootPosts(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID
      )
    } catch {
      composeError = error.localizedDescription
      return nil
    }

    let timestamp = Int64(Date.now.timeIntervalSince1970)
    return SessionDeletionDraft(
      payload: LinkstrPayload(
        conversationID: session.sessionID,
        rootID: makeLocalEventID(),
        kind: .sessionDelete,
        url: nil,
        note: nil,
        timestamp: timestamp
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys,
      sessionID: session.sessionID,
      hadStoredRootPosts: hadStoredRootPosts,
      publishedTransportEventIDs: publishedTransportEventIDs
    )
  }

  private func makeRootPostDraft(
    url: String,
    note: String?,
    sessionID: String
  ) -> RootPostDraft? {
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: url) else {
      composeError = "enter a valid url."
      return nil
    }

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to send posts."
      return nil
    }

    guard
      let recipientPubkeys = resolveOutboundRecipients(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else { return nil }
    guard !recipientPubkeys.isEmpty else {
      composeError = "this session has no active members."
      return nil
    }

    let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedNote = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
    let timestamp = Int64(Date.now.timeIntervalSince1970)

    return RootPostDraft(
      payload: LinkstrPayload(
        conversationID: sessionID,
        rootID: "",
        kind: .root,
        url: normalizedURL,
        note: normalizedNote,
        timestamp: timestamp
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys,
      normalizedURL: normalizedURL
    )
  }

  private func persistSentRootPost(_ draft: RootPostDraft, receipt: SentPayloadReceipt) throws {
    let sessionID = draft.payload.conversationID
    _ = try messageStore.upsertSession(
      ownerPubkey: draft.ownerPubkey,
      sessionID: sessionID,
      name: existingSessionName(for: sessionID, ownerPubkey: draft.ownerPubkey),
      createdByPubkey: draft.senderPubkey,
      updatedAt: .now
    )
    let message = try SessionMessageEntity(
      eventID: receipt.rumorEventID,
      ownerPubkey: draft.ownerPubkey,
      conversationID: sessionID,
      rootID: receipt.rumorEventID,
      kind: .root,
      senderPubkey: draft.senderPubkey,
      url: draft.normalizedURL,
      note: draft.payload.note,
      timestamp: .now,
      readAt: .now,
      linkType: URLClassifier.classify(draft.normalizedURL),
      publishedTransportEventIDs: receipt.publishedEventIDs
    )
    try messageStore.insert(message)
  }

  private func persistReactionState(_ draft: ReactionDraft, eventID: String) throws {
    guard let isActive = draft.payload.reactionActive else { return }
    let emoji = draft.payload.emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !emoji.isEmpty else { return }
    let sessionID = draft.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    let postID = draft.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !postID.isEmpty else { return }

    try messageStore.upsertReaction(
      ownerPubkey: draft.ownerPubkey,
      sessionID: sessionID,
      postID: postID,
      emoji: emoji,
      senderPubkey: draft.senderPubkey,
      isActive: isActive,
      updatedAt: .now,
      eventID: eventID
    )
  }

  private func persistRootDeletion(_ draft: RootDeletionDraft, eventID: String) throws {
    try messageStore.applyRootDeletion(
      ownerPubkey: draft.ownerPubkey,
      sessionID: draft.payload.conversationID,
      rootID: draft.rootID,
      deletedByPubkey: draft.senderPubkey,
      updatedAt: Date(timeIntervalSince1970: TimeInterval(draft.payload.timestamp)),
      eventID: eventID
    )
    discardPendingIncomingReactions(
      sessionID: draft.payload.conversationID,
      rootID: draft.rootID
    )
  }

  private func persistSessionDeletion(_ draft: SessionDeletionDraft, eventID: String) throws {
    _ = try messageStore.applySessionDeletion(
      ownerPubkey: draft.ownerPubkey,
      sessionID: draft.sessionID,
      deletedByPubkey: draft.senderPubkey,
      updatedAt: Date(timeIntervalSince1970: TimeInterval(draft.payload.timestamp)),
      eventID: eventID
    )
    discardPendingIncomingSessionData(sessionID: draft.sessionID)
    invalidateMemberIntervalCache(sessionID: draft.sessionID)
    if pendingSessionNavigationID == draft.sessionID {
      pendingSessionNavigationID = nil
    }
    schedulePushStateSync()
  }

  private func publishFollowListAwaitingRelayAcceptance(followedPubkeyHexes: [String]) async throws
    -> String
  {
    if let publishFollowListOverride = testingOverrides.publishFollowList {
      return try await publishFollowListOverride(followedPubkeyHexes)
    }
    return try await nostrService.publishFollowListAwaitingRelayAcceptance(
      followedPubkeyHexes: followedPubkeyHexes
    )
  }

  private func publishEventAwaitingRelayAcceptance(_ event: NostrEvent) async throws -> String {
    if let publishRelayEventOverride = testingOverrides.publishRelayEvent {
      return try await publishRelayEventOverride(event)
    }
    return try await nostrService.publishEventAwaitingRelayAcceptance(event)
  }

  private func sendPayloadAwaitingRelayAcceptance(
    payload: LinkstrPayload,
    recipientPubkeyHexes: [String]
  ) async throws -> SentPayloadReceipt {
    if let sendPayloadOverride = testingOverrides.sendPayload {
      guard !recipientPubkeyHexes.isEmpty else {
        throw NostrServiceError.invalidPubkey
      }
      return try await sendPayloadOverride(payload, recipientPubkeyHexes)
    }
    return try await nostrService.sendAwaitingRelayAcceptance(
      payload: payload,
      toMany: recipientPubkeyHexes
    )
  }

  private func localSendReceipt(withRumorEventID rumorEventID: String) -> SentPayloadReceipt {
    SentPayloadReceipt(rumorEventID: rumorEventID, publishedEventIDs: [])
  }

  private func normalizedMemberPubkeys(fromNPubs memberNPubs: [String], myPubkey: String)
    -> [String]
  {
    var members: [String] = []
    if let normalizedMyPubkey = NostrValueNormalizer.normalizedPubkeyHex(myPubkey) {
      members.append(normalizedMyPubkey)
    }
    for npub in memberNPubs {
      guard
        let memberPubkey = NostrValueNormalizer.normalizedPubkeyHex(
          fromAnyPublicKeyString: npub)
      else { continue }
      members.append(memberPubkey)
    }

    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(members)
  }

  private func activeMemberPubkeys(sessionID: String, ownerPubkey: String) throws -> [String] {
    let members = try messageStore.members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: true
    ).map(\.memberPubkey)
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(members)
  }

  private func resolveOutboundRecipients(
    sessionID: String,
    ownerPubkey: String,
    senderPubkey: String
  ) -> [String]? {
    do {
      guard
        try messageStore.isMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: senderPubkey,
          at: .now
        )
      else {
        composeError = "you're no longer a member of this session."
        return nil
      }
      let recipientPubkeys = try activeMemberPubkeys(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey
      )
      guard recipientPubkeys.contains(senderPubkey) else {
        composeError = "you're no longer a member of this session."
        return nil
      }
      return recipientPubkeys
    } catch {
      composeError = error.localizedDescription
      return nil
    }
  }

  private func resolveDeletionRecipients(
    sessionID: String,
    ownerPubkey: String,
    senderPubkey: String
  ) -> [String]? {
    do {
      let knownMemberPubkeys = try messageStore.members(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        activeOnly: false
      ).map(\.memberPubkey)
      let recipientPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(
        knownMemberPubkeys + [senderPubkey])
      guard recipientPubkeys.contains(senderPubkey) else {
        composeError = "this post is no longer associated with a valid session membership set."
        return nil
      }
      return recipientPubkeys
    } catch {
      composeError = error.localizedDescription
      return nil
    }
  }

  private func mergedPubkeys(_ first: [String], _ second: [String]) -> [String] {
    NostrValueNormalizer.dedupedNormalizedPubkeyHexes(first + second)
  }

  private func makeRelayDeletionEvent(
    publishedTransportEventIDs: [String],
    reason: String,
    signedBy keypair: Keypair
  ) throws
    -> NostrEvent
  {
    let normalizedEventIDs =
      publishedTransportEventIDs.compactMap(NostrValueNormalizer.normalizedEventID)
    guard !normalizedEventIDs.isEmpty else {
      throw LinkstrPayloadError.invalidRootID
    }

    let eventTags = try normalizedEventIDs.map { try customTag(name: "e", value: $0) }

    return try NostrEvent.Builder<NostrEvent>(kind: .deletion)
      .content(reason)
      .appendTags(contentsOf: eventTags)
      .appendTags(try customTag(name: "k", value: String(EventKind.giftWrap.rawValue)))
      .build(signedBy: keypair)
  }

  private func makeVanishEvent(relayURLs: [String], signedBy keypair: Keypair) throws -> NostrEvent
  {
    let normalizedRelayURLs =
      Array(
        Set(
          relayURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )
      )
      .sorted()

    let relayTags: [Tag]
    if normalizedRelayURLs.isEmpty {
      relayTags = try [customTag(name: "relay", value: "ALL_RELAYS")]
    } else {
      relayTags = try normalizedRelayURLs.map { try customTag(name: "relay", value: $0) }
    }

    return try NostrEvent.Builder<NostrEvent>(kind: .unknown(62))
      .content("account deletion request")
      .appendTags(contentsOf: relayTags)
      .build(signedBy: keypair)
  }

  private func customTag(name: String, value: String) throws -> Tag {
    let rawTag = [name, value]
    let data = try JSONEncoder().encode(rawTag)
    return try JSONDecoder().decode(Tag.self, from: data)
  }

  private func existingSessionName(for sessionID: String, ownerPubkey: String) -> String {
    do {
      if let session = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
        let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    } catch {
      // Ignore fetch failures and fall back to a generic title.
    }
    return "session"
  }

  private func updatedFollowedPubkeys(
    ownerPubkey: String,
    mutating mutation: (inout Set<String>) -> Void
  ) throws -> [String] {
    var followedPubkeys = Set(try contactStore.followedPubkeys(ownerPubkey: ownerPubkey))
    mutation(&followedPubkeys)
    return followedPubkeys.sorted()
  }

  private func persistLocalFollowedPubkeys(
    ownerPubkey: String,
    followedPubkeys: [String],
    aliasMutation: (() throws -> Void)? = nil
  ) throws {
    try applyFollowListState(
      ownerPubkey: ownerPubkey,
      followedPubkeys: followedPubkeys,
      createdAt: Date.now,
      eventID: nil,
      aliasMutation: aliasMutation
    )
  }

  private func applyFollowListState(
    ownerPubkey: String,
    followedPubkeys: [String],
    createdAt: Date,
    eventID: String?,
    aliasMutation: (() throws -> Void)? = nil
  ) throws {
    try contactStore.replaceFollowedPubkeys(
      ownerPubkey: ownerPubkey,
      pubkeyHexes: followedPubkeys
    )
    try aliasMutation?()
    latestAppliedFollowListCreatedAt = createdAt
    latestAppliedFollowListEventID = eventID
    persistFollowListState(ownerPubkey: ownerPubkey, createdAt: createdAt, eventID: eventID)
  }

  @discardableResult
  private func applySessionSnapshotLocally(
    ownerPubkey: String,
    sessionID: String,
    createdByPubkey: String,
    sessionName: String?,
    memberPubkeys: [String],
    updatedAt: Date,
    eventID: String,
    isArchived: Bool? = nil
  ) throws -> SessionEntity? {
    let normalizedName = normalizedSessionName(sessionName)
    let sessionEntity: SessionEntity

    if let existing = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
      let renameUpdatedAt = max(existing.updatedAt, updatedAt)
      sessionEntity = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: existing.name,
        createdByPubkey: existing.createdByPubkey,
        updatedAt: updatedAt,
        isArchived: isArchived ?? existing.isArchived
      )

      if let normalizedName, sessionEntity.name != normalizedName {
        try sessionEntity.updateName(normalizedName, updatedAt: renameUpdatedAt)
        try modelContext.save()
      }
    } else {
      guard let normalizedName else { return nil }
      sessionEntity = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: normalizedName,
        createdByPubkey: createdByPubkey,
        updatedAt: updatedAt,
        isArchived: isArchived
      )
    }

    try messageStore.applyMemberSnapshot(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      memberPubkeys: memberPubkeys,
      updatedAt: updatedAt,
      eventID: eventID
    )
    invalidateMemberIntervalCache(sessionID: sessionID)
    return sessionEntity
  }

  @discardableResult
  func addContact(
    npub: String,
    alias: String,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }

    let targetPubkey: String
    do {
      targetPubkey = try contactStore.normalizeFollowTarget(npub)
    } catch {
      report(error: error)
      return false
    }

    let normalizedAlias = contactStore.normalizeAlias(alias)
    if contactStore.hasContact(ownerPubkey: ownerPubkey, withTargetPubkey: targetPubkey) {
      do {
        try contactStore.updateAlias(
          ownerPubkey: ownerPubkey,
          targetPubkey: targetPubkey,
          alias: normalizedAlias
        )
        composeError = nil
        return true
      } catch {
        report(error: error)
        return false
      }
    }

    let nextFollowedPubkeys: [String]
    do {
      nextFollowedPubkeys = try updatedFollowedPubkeys(ownerPubkey: ownerPubkey) {
        followedPubkeys in
        followedPubkeys.insert(targetPubkey)
      }
    } catch {
      report(error: error)
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishFollowListAwaitingRelayAcceptance(
          followedPubkeyHexes: nextFollowedPubkeys
        )
      }
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    do {
      try persistLocalFollowedPubkeys(
        ownerPubkey: ownerPubkey,
        followedPubkeys: nextFollowedPubkeys
      ) { [self] in
        if let normalizedAlias {
          try contactStore.updateAlias(
            ownerPubkey: ownerPubkey,
            targetPubkey: targetPubkey,
            alias: normalizedAlias
          )
        }
      }
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func updateContactAlias(_ contact: ContactEntity, alias: String) -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }

    do {
      let normalizedAlias = contactStore.normalizeAlias(alias)
      try contactStore.updateAlias(contact, ownerPubkey: ownerPubkey, alias: normalizedAlias)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func removeContact(
    _ contact: ContactEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }
    guard contact.ownerPubkey == ownerPubkey else {
      composeError = "this contact belongs to a different account."
      return false
    }

    let nextFollowedPubkeys: [String]
    do {
      nextFollowedPubkeys = try updatedFollowedPubkeys(ownerPubkey: ownerPubkey) {
        followedPubkeys in
        followedPubkeys.remove(contact.targetPubkey)
      }
    } catch {
      report(error: error)
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishFollowListAwaitingRelayAcceptance(
          followedPubkeyHexes: nextFollowedPubkeys
        )
      }
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    do {
      try persistLocalFollowedPubkeys(
        ownerPubkey: ownerPubkey,
        followedPubkeys: nextFollowedPubkeys
      )
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  func setSessionArchived(sessionID: String, archived: Bool) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.setSessionArchived(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        archived: archived
      )
      schedulePushStateSync()
    } catch {
      report(error: error)
    }
  }

  func markRootPostRead(postID: String) {
    guard let myPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.markRootPostRead(postID: postID, ownerPubkey: myPubkey, myPubkey: myPubkey)
    } catch {
      report(error: error)
    }
  }

  @discardableResult
  func addRelay(url: String) -> Bool {
    guard let parsedURL = normalizedRelayURL(from: url)
    else {
      composeError = "enter a valid relay url (ws:// or wss://)."
      return false
    }
    return performRelayMutation {
      try relayStore.addRelay(url: parsedURL)
    }
  }

  func removeRelay(_ relay: RelayEntity) {
    performRelayMutation {
      try relayStore.removeRelay(relay)
    }
  }

  func toggleRelay(_ relay: RelayEntity) {
    performRelayMutation {
      try relayStore.toggleRelay(relay)
    }
  }

  func resetDefaultRelays() {
    performRelayMutation {
      try relayStore.resetDefaultRelays()
    }
  }

  func clearPendingSessionNavigationID() {
    pendingSessionNavigationID = nil
  }

  @discardableResult
  private func performRelayMutation(_ mutation: () throws -> Void) -> Bool {
    do {
      try mutation()
      composeError = nil
    } catch {
      report(error: error)
      return false
    }
    pruneRuntimeRelayStatusCache()
    scheduleNostrStartup(maxAttempts: IdentityLoadRetryDefaults.activeAttempts)
    return true
  }

  func clearCachedMedia() {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage local storage."
      return
    }
    clearCachedMedia(ownerPubkey: ownerPubkey)
  }

  private func clearCachedMedia(ownerPubkey: String) {
    do {
      try messageStore.clearCachedMedia(ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func clearableCachedMediaBytes() -> Int64 {
    let currentAccountUsage: ManagedStorageUsage
    if let ownerPubkey = identityService.pubkeyHex {
      currentAccountUsage =
        (try? messageStore.managedStorageUsage(ownerPubkey: ownerPubkey)) ?? .zero
    } else {
      currentAccountUsage = .zero
    }

    return currentAccountUsage.cachedMediaBytes
  }

  @discardableResult
  func refreshPostMetadata(_ message: SessionMessageEntity) async -> Bool {
    do {
      if let urlString = message.url, let url = URL(string: urlString) {
        await invalidateTransientMediaCaches(for: url)
      }
      let didRefreshMetadata = try await refreshMetadata(for: message, force: true)
      if didRefreshMetadata {
        try modelContext.save()
      }
      composeError = nil
      return didRefreshMetadata
    } catch {
      report(error: error)
      return false
    }
  }

  private func persistIncomingFollowList(_ incoming: ReceivedFollowList) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    guard incoming.authorPubkey == ownerPubkey else { return }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(incoming.eventID)

    if !NostrValueNormalizer.shouldApplyStateUpdate(
      currentUpdatedAt: latestAppliedFollowListCreatedAt,
      currentEventID: latestAppliedFollowListEventID,
      incomingUpdatedAt: incoming.createdAt,
      incomingEventID: normalizedEventID
    ) {
      return
    }

    do {
      try applyFollowListState(
        ownerPubkey: ownerPubkey,
        followedPubkeys: incoming.followedPubkeys,
        createdAt: incoming.createdAt,
        eventID: normalizedEventID
      )
    } catch {
      report(error: error)
    }
  }

  private func persistIncomingProfileMetadata(_ incoming: ReceivedProfileMetadata) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(incoming.eventID)

    if incoming.authorPubkey == ownerPubkey {
      guard
        NostrValueNormalizer.shouldApplyStateUpdate(
          currentUpdatedAt: latestAppliedProfileMetadataCreatedAt,
          currentEventID: latestAppliedProfileMetadataEventID,
          incomingUpdatedAt: incoming.createdAt,
          incomingEventID: normalizedEventID
        )
      else {
        return
      }

      persistOwnProfileMetadataState(
        ownerPubkey: ownerPubkey,
        chosenName: incoming.chosenName,
        content: incoming.rawContent,
        createdAt: incoming.createdAt,
        eventID: normalizedEventID
      )
      return
    }

    updateRemoteProfileSnapshot(
      pubkeyHex: incoming.authorPubkey,
      chosenName: incoming.chosenName,
      createdAt: incoming.createdAt,
      eventID: normalizedEventID
    )
  }

  #if DEBUG
    func ingestForTesting(_ incoming: ReceivedDirectMessage) {
      persistIncoming(incoming)
    }

    func simulateInitialHistoricalRestoreCompletionForTesting() {
      finishInitialHistoricalRestore()
    }

    var testingPendingMetadataRefreshCount: Int {
      pendingMetadataRefreshes.count
    }

    func enqueuePendingIncomingForTesting(_ incoming: ReceivedDirectMessage) {
      enqueuePendingIncomingMessage(PendingIncomingMessage(incoming))
    }

    func beginForegroundCycleForTesting() {
      beginForegroundCycle()
    }

    func simulateRuntimeRelayStatusForTesting(
      relayURL: String,
      status: RelayHealthStatus,
      message: String? = nil
    ) {
      updateRuntimeRelayStatus(relayURL: relayURL, status: status, message: message)
      try? refreshRelayConnectivityAlert()
    }

    func ingestFollowListForTesting(_ incoming: ReceivedFollowList) {
      persistIncomingFollowList(incoming)
    }

    func ingestProfileMetadataForTesting(_ incoming: ReceivedProfileMetadata) {
      persistIncomingProfileMetadata(incoming)
    }
  #endif

  private func persistIncoming(_ incoming: ReceivedDirectMessage) {
    evaluateInitialHistoricalUnreadPolicyIfNeeded(for: incoming)
    let pending = PendingIncomingMessage(incoming)
    switch reduceIncoming(pending) {
    case .applied:
      removePendingIncomingMessage(eventID: pending.eventID)
      drainTargetedPendingMessages(for: incoming)
      drainPendingIncomingMessagesIfNeeded()
    case .ignored:
      removePendingIncomingMessage(eventID: pending.eventID)
    case .pending:
      enqueuePendingIncomingMessage(pending)
    }
  }

  private func drainTargetedPendingMessages(for incoming: ReceivedDirectMessage) {
    guard !pendingIncomingMessages.isEmpty else { return }
    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }

    switch incoming.payload.kind {
    case .root:
      // A root post just landed — try resolving pending reactions for this root.
      let rootID = incoming.eventID
      drainPendingMessages { pending in
        pending.incoming.payload.kind == .reaction
          && pending.incoming.payload.conversationID.trimmingCharacters(
            in: .whitespacesAndNewlines) == sessionID
          && pending.incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
            == rootID
      }
    case .sessionCreate, .sessionMembers:
      // Session state just landed — try resolving pending roots/reactions/deletions for this session.
      drainPendingMessages { pending in
        let kind = pending.incoming.payload.kind
        guard
          kind == .root
            || kind == .reaction
            || kind == .rootDelete
            || kind == .sessionDelete
        else { return false }
        return pending.incoming.payload.conversationID.trimmingCharacters(
          in: .whitespacesAndNewlines) == sessionID
      }
    default:
      break
    }
  }

  private func drainPendingMessages(matching predicate: (PendingIncomingMessage) -> Bool) {
    guard !isDrainingPendingIncomingMessages else { return }
    var candidates: [(Int, PendingIncomingMessage)] = []
    for (index, pending) in pendingIncomingMessages.enumerated() where predicate(pending) {
      candidates.append((index, pending))
    }
    guard !candidates.isEmpty else { return }

    isDrainingPendingIncomingMessages = true
    defer { isDrainingPendingIncomingMessages = false }

    var indicesToRemove = IndexSet()
    var madeProgress = true
    while madeProgress {
      madeProgress = false
      var stillPending: [(Int, PendingIncomingMessage)] = []
      for (originalIndex, pending) in candidates {
        guard !indicesToRemove.contains(originalIndex) else { continue }
        switch reduceIncoming(pending) {
        case .applied:
          indicesToRemove.insert(originalIndex)
          madeProgress = true
        case .ignored:
          indicesToRemove.insert(originalIndex)
        case .pending:
          stillPending.append((originalIndex, pending))
        }
      }
      candidates = stillPending
    }

    if !indicesToRemove.isEmpty {
      pendingIncomingMessages = pendingIncomingMessages.enumerated().compactMap { index, msg in
        indicesToRemove.contains(index) ? nil : msg
      }
    }
  }

  private func reduceIncoming(_ pending: PendingIncomingMessage) -> IncomingPersistenceOutcome {
    switch pending.incoming.payload.kind {
    case .sessionCreate:
      return persistIncomingSessionCreate(pending.incoming)
    case .sessionDelete:
      return persistIncomingSessionDelete(pending.incoming)
    case .sessionMembers:
      return persistIncomingSessionMembers(pending.incoming)
    case .reaction:
      return persistIncomingReaction(pending.incoming)
    case .root:
      return persistIncomingRootPost(
        pending.incoming,
        transportEventIDs: pending.transportEventIDs
      )
    case .rootDelete:
      return persistIncomingRootDeletion(pending.incoming)
    }
  }

  private func enqueuePendingIncomingMessage(_ pending: PendingIncomingMessage) {
    if let index = pendingIncomingMessages.firstIndex(where: { $0.eventID == pending.eventID }) {
      pendingIncomingMessages[index].mergeDuplicate(pending.incoming)
      return
    }
    pendingIncomingMessages.append(pending)
  }

  private func removePendingIncomingMessage(eventID: String) {
    pendingIncomingMessages.removeAll { $0.eventID == eventID }
  }

  private func discardPendingIncomingReactions(sessionID: String, rootID: String) {
    pendingIncomingMessages.removeAll { pending in
      pending.incoming.payload.kind == .reaction
        && pending.incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
          == sessionID
        && pending.incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines) == rootID
    }
  }

  private func discardPendingIncomingSessionData(sessionID: String) {
    pendingIncomingMessages.removeAll { pending in
      pending.incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        == sessionID
    }
  }

  private func discardPendingIncomingSessionDependents(sessionID: String) {
    pendingIncomingMessages.removeAll { pending in
      let payload = pending.incoming.payload
      guard payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
      else {
        return false
      }
      return payload.kind != .sessionDelete
    }
  }

  private func drainPendingIncomingMessagesIfNeeded() {
    guard !isDrainingPendingIncomingMessages else { return }
    guard !pendingIncomingMessages.isEmpty else { return }

    isDrainingPendingIncomingMessages = true
    defer { isDrainingPendingIncomingMessages = false }

    var madeProgress = true
    while madeProgress {
      madeProgress = false
      var nextPending: [PendingIncomingMessage] = []

      for pending in pendingIncomingMessages {
        switch reduceIncoming(pending) {
        case .applied:
          madeProgress = true
        case .ignored:
          continue
        case .pending:
          nextPending.append(pending)
        }
      }

      pendingIncomingMessages = nextPending
    }
  }

  private func normalizedSessionName(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func hasDeletedSession(ownerPubkey: String, sessionID: String) throws -> Bool {
    try messageStore.sessionDeletionTombstone(sessionID: sessionID, ownerPubkey: ownerPubkey) != nil
  }

  private func sessionDeletionAuthorityPubkey(ownerPubkey: String, sessionID: String) throws
    -> String?
  {
    if let tombstone = try messageStore.sessionDeletionTombstone(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey
    ) {
      return tombstone.deletedByPubkey
    }
    return try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)?.createdByPubkey
  }

  private func resetInitialHistoricalUnreadPolicy() {
    shouldSuppressUnreadDuringInitialHistoricalRestore = false
    hasEvaluatedInitialHistoricalUnreadPolicy = false
  }

  private func finishInitialHistoricalRestore() {
    shouldSuppressUnreadDuringInitialHistoricalRestore = false
    hasEvaluatedInitialHistoricalUnreadPolicy = true
    drainPendingIncomingMessagesIfNeeded()
  }

  private func evaluateInitialHistoricalUnreadPolicyIfNeeded(for incoming: ReceivedDirectMessage) {
    guard incoming.source == .historical else { return }
    guard !hasEvaluatedInitialHistoricalUnreadPolicy else { return }
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    do {
      shouldSuppressUnreadDuringInitialHistoricalRestore =
        !(try messageStore.hasPersistedConversationState(ownerPubkey: ownerPubkey))
    } catch {
      shouldSuppressUnreadDuringInitialHistoricalRestore = false
      report(error: error)
    }
    hasEvaluatedInitialHistoricalUnreadPolicy = true
  }

  private func resolveInboundSession(
    ownerPubkey: String,
    sessionID: String,
    senderPubkey: String,
    timestamp: Date,
    source: DirectMessageIngestSource
  ) -> InboundSessionResolution {
    do {
      if try hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) {
        return .ignored
      }
      guard let session = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)
      else {
        return .pending
      }
      guard
        inboundMembershipIsActive(
          sessionID: sessionID,
          senderPubkey: senderPubkey,
          timestamp: timestamp,
          source: source
        )
      else {
        if source == .live, session.membershipStateUpdatedAt.map({ $0 <= timestamp }) != false {
          return .pending
        }
        return .ignored
      }
      return .ready(session)
    } catch {
      report(error: error)
      return .ignored
    }
  }

  private func persistIncomingSessionCreate(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome
  {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return .ignored
    }
    guard members.contains(incoming.senderPubkey) else { return .ignored }
    guard members.contains(ownerPubkey) else { return .ignored }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) else {
        return .ignored
      }
      let existing = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)
      if let existing {
        guard existing.createdByPubkey == incoming.senderPubkey else { return .ignored }
        guard
          try messageStore.shouldApplyMemberSnapshot(
            ownerPubkey: ownerPubkey,
            sessionID: sessionID,
            updatedAt: incoming.createdAt,
            eventID: incoming.eventID
          )
        else {
          return .ignored
        }
      }

      guard
        try applySessionSnapshotLocally(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          createdByPubkey: incoming.senderPubkey,
          sessionName: normalizedSessionName(incoming.payload.sessionName),
          memberPubkeys: members,
          updatedAt: incoming.createdAt,
          eventID: incoming.eventID
        ) != nil
      else {
        return .ignored
      }
      return .applied
    } catch {
      report(error: error)
      return .ignored
    }
  }

  private func persistIncomingSessionMembers(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome
  {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return .ignored
    }
    guard members.contains(incoming.senderPubkey) else { return .ignored }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) else {
        return .ignored
      }
      let existing = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)
      if let existing {
        guard existing.createdByPubkey == incoming.senderPubkey else { return .ignored }
        guard
          try messageStore.shouldApplyMemberSnapshot(
            ownerPubkey: ownerPubkey,
            sessionID: sessionID,
            updatedAt: incoming.createdAt,
            eventID: incoming.eventID
          )
        else {
          return .ignored
        }
      } else {
        guard members.contains(ownerPubkey) else { return .ignored }
      }

      guard
        try applySessionSnapshotLocally(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          createdByPubkey: incoming.senderPubkey,
          sessionName: normalizedSessionName(incoming.payload.sessionName),
          memberPubkeys: members,
          updatedAt: incoming.createdAt,
          eventID: incoming.eventID,
          isArchived: existing?.isArchived
        ) != nil
      else {
        return .ignored
      }
      return .applied
    } catch {
      report(error: error)
      return .ignored
    }
  }

  private func persistIncomingSessionDelete(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome
  {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }

    do {
      guard
        let authorityPubkey = try sessionDeletionAuthorityPubkey(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID
        )
      else {
        return .pending
      }
      guard authorityPubkey == incoming.senderPubkey else { return .ignored }

      let didApply = try messageStore.applySessionDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        deletedByPubkey: incoming.senderPubkey,
        updatedAt: incoming.createdAt,
        eventID: incoming.eventID
      )
      let tombstoneExists = try hasDeletedSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID
      )
      let isDeleted = didApply || tombstoneExists
      if isDeleted {
        discardPendingIncomingSessionDependents(sessionID: sessionID)
        invalidateMemberIntervalCache(sessionID: sessionID)
        if pendingSessionNavigationID == sessionID {
          pendingSessionNavigationID = nil
        }
        schedulePushStateSync()
        return .applied
      }
      return .ignored
    } catch {
      report(error: error)
      return .ignored
    }
  }

  private func persistIncomingReaction(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome
  {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }
    guard let isActive = incoming.payload.reactionActive else { return .ignored }
    let emoji = incoming.payload.emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !emoji.isEmpty else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }
    let postID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !postID.isEmpty else { return .ignored }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) else {
        return .ignored
      }
    } catch {
      report(error: error)
      return .ignored
    }

    switch resolveInboundSession(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      senderPubkey: incoming.senderPubkey,
      timestamp: incoming.createdAt,
      source: incoming.source
    ) {
    case .ready:
      break
    case .pending:
      return .pending
    case .ignored:
      return .ignored
    }

    do {
      guard
        let root = try messageStore.rootPost(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          rootID: postID
        )
      else {
        return .pending
      }
      if try messageStore.hasRootDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: postID,
        deletedByPubkey: root.senderPubkey
      ) {
        return .ignored
      }

      try messageStore.upsertReaction(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        postID: postID,
        emoji: emoji,
        senderPubkey: incoming.senderPubkey,
        isActive: isActive,
        updatedAt: incoming.createdAt,
        eventID: incoming.eventID
      )
      return .applied
    } catch {
      report(error: error)
      return .ignored
    }
  }

  private func persistIncomingRootDeletion(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome
  {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }
    let rootID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootID.isEmpty else { return .ignored }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) else {
        return .ignored
      }
      if try messageStore.rootDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: rootID,
        deletedByPubkey: incoming.senderPubkey
      ) != nil {
        _ = try messageStore.applyRootDeletion(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          rootID: rootID,
          deletedByPubkey: incoming.senderPubkey,
          updatedAt: incoming.createdAt,
          eventID: incoming.eventID
        )
        discardPendingIncomingReactions(sessionID: sessionID, rootID: rootID)
        return .applied
      }

      guard
        let existingRoot = try messageStore.rootPost(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          rootID: rootID
        )
      else {
        return .pending
      }

      let incomingSenderHash = LocalDataCrypto.shared.digestHex(incoming.senderPubkey)
      guard existingRoot.senderMatchesHash(incomingSenderHash) else {
        return .ignored
      }

      _ = try messageStore.applyRootDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: rootID,
        deletedByPubkey: incoming.senderPubkey,
        updatedAt: incoming.createdAt,
        eventID: incoming.eventID
      )
      discardPendingIncomingReactions(sessionID: sessionID, rootID: rootID)
      return .applied
    } catch {
      report(error: error)
      return .ignored
    }
  }

  private func persistIncomingRootPost(
    _ incoming: ReceivedDirectMessage,
    transportEventIDs: [String]
  )
    -> IncomingPersistenceOutcome
  {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }
    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) else {
        return .ignored
      }
    } catch {
      report(error: error)
      return .ignored
    }
    let payloadRootID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !payloadRootID.isEmpty, payloadRootID != incoming.eventID {
      return .ignored
    }

    let normalizedURL: String
    guard let payloadURL = incoming.payload.url,
      let resolvedURL = LinkstrURLValidator.normalizedWebURL(from: payloadURL)
    else {
      return .ignored
    }
    normalizedURL = resolvedURL

    let existingSession: SessionEntity
    switch resolveInboundSession(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      senderPubkey: incoming.senderPubkey,
      timestamp: incoming.createdAt,
      source: incoming.source
    ) {
    case .ready(let session):
      existingSession = session
    case .pending:
      return .pending
    case .ignored:
      return .ignored
    }

    do {
      if try messageStore.hasRootDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: incoming.eventID,
        deletedByPubkey: incoming.senderPubkey
      ) {
        discardPendingIncomingReactions(sessionID: sessionID, rootID: incoming.eventID)
        return .ignored
      }

      if let existing = try messageStore.rootPost(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: incoming.eventID
      ) {
        if existing.appendPublishedTransportEventIDs(transportEventIDs) {
          try modelContext.save()
        }
        return .applied
      }

      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: existingSession.name,
        createdByPubkey: existingSession.createdByPubkey,
        updatedAt: incoming.createdAt,
        isArchived: existingSession.isArchived
      )

      let isEchoedOutgoing = ownerPubkey == incoming.senderPubkey
      let shouldMarkReadOnInsert =
        isEchoedOutgoing
        || (incoming.source == .historical
          && shouldSuppressUnreadDuringInitialHistoricalRestore)
      let message = try SessionMessageEntity(
        eventID: incoming.eventID,
        ownerPubkey: ownerPubkey,
        conversationID: sessionID,
        rootID: incoming.eventID,
        kind: .root,
        senderPubkey: incoming.senderPubkey,
        url: normalizedURL,
        note: incoming.payload.note,
        timestamp: incoming.createdAt,
        readAt: shouldMarkReadOnInsert ? incoming.createdAt : nil,
        linkType: URLClassifier.classify(normalizedURL),
        publishedTransportEventIDs: transportEventIDs
      )
      try messageStore.insert(message)
      return .applied
    } catch {
      if let existing = try? messageStore.rootPost(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: incoming.eventID
      ) {
        if existing.appendPublishedTransportEventIDs(transportEventIDs) {
          try? modelContext.save()
        }
        return .applied
      }
      report(error: error)
      return .ignored
    }
  }

  private func inboundMembershipIsActive(
    sessionID: String,
    senderPubkey: String,
    timestamp: Date,
    source: DirectMessageIngestSource
  ) -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else { return false }
    let myPubkey = ownerPubkey

    do {
      if source == .live {
        guard
          try cachedIsMemberActive(
            sessionID: sessionID,
            ownerPubkey: ownerPubkey,
            memberPubkey: senderPubkey,
            at: .now
          )
        else {
          return false
        }
        guard
          try cachedIsMemberActive(
            sessionID: sessionID,
            ownerPubkey: ownerPubkey,
            memberPubkey: myPubkey,
            at: .now
          )
        else {
          return false
        }
      }
      guard
        try cachedIsMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: senderPubkey,
          at: timestamp
        )
      else {
        return false
      }
      guard
        try cachedIsMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: myPubkey,
          at: timestamp
        )
      else {
        return false
      }
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func enqueueMetadataRefresh(for message: SessionMessageEntity) {
    guard shouldFetchLinkMetadataForCurrentProcess() else { return }
    guard message.kind == .root else { return }
    guard message.url != nil else { return }
    guard needsMetadataRefresh(message) else { return }

    let storageID = message.storageID
    guard !enqueuedMetadataStorageIDs.contains(storageID) else { return }
    enqueuedMetadataStorageIDs.insert(storageID)
    pendingMetadataRefreshes.append(PendingMetadataRefresh(storageID: storageID))
    processMetadataQueueIfNeeded()
  }

  func refreshMetadataForVisiblePostIfNeeded(_ message: SessionMessageEntity) {
    enqueueMetadataRefresh(for: message)
  }

  func cancelPendingMetadataRefreshesForHiddenSession() {
    metadataRefreshQueueGeneration += 1
    pendingMetadataRefreshes.removeAll(keepingCapacity: true)
    pendingMetadataRefreshHead = 0
    if let activeMetadataRefreshStorageID {
      enqueuedMetadataStorageIDs = [activeMetadataRefreshStorageID]
    } else {
      enqueuedMetadataStorageIDs.removeAll()
      isProcessingMetadataQueue = false
    }
  }

  private func processMetadataQueueIfNeeded() {
    guard !isProcessingMetadataQueue else { return }
    isProcessingMetadataQueue = true
    let generation = metadataRefreshQueueGeneration

    Task { @MainActor in
      var hasPendingSave = false
      while generation == metadataRefreshQueueGeneration,
        pendingMetadataRefreshHead < pendingMetadataRefreshes.count
      {
        let request = pendingMetadataRefreshes[pendingMetadataRefreshHead]
        pendingMetadataRefreshHead += 1
        activeMetadataRefreshStorageID = request.storageID

        do {
          guard let message = try messageStore.message(storageID: request.storageID) else {
            enqueuedMetadataStorageIDs.remove(request.storageID)
            activeMetadataRefreshStorageID = nil
            continue
          }
          let didChange = try await refreshMetadata(for: message)
          if didChange { hasPendingSave = true }
        } catch {
          report(error: error)
        }
        enqueuedMetadataStorageIDs.remove(request.storageID)
        activeMetadataRefreshStorageID = nil
      }

      if hasPendingSave {
        try? modelContext.save()
      }

      if generation == metadataRefreshQueueGeneration {
        pendingMetadataRefreshes.removeAll(keepingCapacity: true)
        pendingMetadataRefreshHead = 0
      }
      isProcessingMetadataQueue = false
      if generation != metadataRefreshQueueGeneration, !pendingMetadataRefreshes.isEmpty {
        processMetadataQueueIfNeeded()
      }
    }
  }

  private func refreshMetadata(for message: SessionMessageEntity, force: Bool = false) async throws
    -> Bool
  {
    guard let url = message.url else { return false }
    guard force || needsMetadataRefresh(message) else { return false }

    let preview: LinkPreviewData?
    if let fetchLinkPreview = testingOverrides.fetchLinkPreview {
      preview = await fetchLinkPreview(url)
    } else {
      preview = await URLMetadataService.shared.fetchPreview(for: url)
    }
    guard let preview else { return false }

    let currentTitle = LinkMetadataRefreshPolicy.normalizedTitle(message.metadataTitle)
    let previewTitle = LinkMetadataRefreshPolicy.normalizedTitle(preview.title)
    let resolvedTitle = previewTitle ?? currentTitle

    let currentThumbnail = ManagedLocalFileScope.shared.normalizedManagedPath(message.thumbnailURL)
    let previewThumbnail = ManagedLocalFileScope.shared.normalizedManagedPath(preview.thumbnailPath)
    let resolvedThumbnail: String?
    if let previewThumbnail {
      resolvedThumbnail = previewThumbnail
    } else if let currentThumbnail, FileManager.default.fileExists(atPath: currentThumbnail) {
      resolvedThumbnail = currentThumbnail
    } else {
      resolvedThumbnail = nil
    }

    guard resolvedTitle != currentTitle || resolvedThumbnail != currentThumbnail else {
      return false
    }

    try message.setMetadata(title: resolvedTitle, thumbnailURL: resolvedThumbnail)
    return true
  }

  private func needsMetadataRefresh(_ message: SessionMessageEntity) -> Bool {
    guard message.kind == .root else { return false }
    guard message.url != nil else { return false }
    return LinkMetadataRefreshPolicy.needsRefresh(
      linkType: message.linkType,
      title: message.metadataTitle,
      thumbnailPath: ManagedLocalFileScope.shared.normalizedManagedPath(message.thumbnailURL)
    )
  }

  private func invalidateTransientMediaCaches(for url: URL) async {
    await URLCanonicalizationService.shared.invalidate(for: url)

    switch URLClassifier.classify(url) {
    case .twitter:
      await TwitterStatusResolutionService.shared.invalidate(for: url)
    case .instagram, .tiktok, .facebook:
      await SocialPostResolutionService.shared.invalidate(for: url)
    case .youtube, .rumble, .generic:
      break
    }
  }

  private func resetFollowListStateInMemory() {
    latestAppliedFollowListCreatedAt = nil
    latestAppliedFollowListEventID = nil
  }

  private func resetRemoteProfileStateInMemory() {
    remoteProfilesByPubkey = [:]
    inFlightRemoteProfilePubkeys.removeAll()
    pendingRemoteProfilePubkeys.removeAll()
  }

  private func resetProfileMetadataStateInMemory() {
    latestAppliedProfileMetadataCreatedAt = nil
    latestAppliedProfileMetadataEventID = nil
    currentProfileMetadataContent = nil
    currentProfileName = nil
  }

  private func loadPersistedFollowListState(ownerPubkey: String) {
    do {
      let watermark = try accountStateStore.followListWatermark(ownerPubkey: ownerPubkey)
      latestAppliedFollowListCreatedAt = watermark.createdAt
      latestAppliedFollowListEventID = NostrValueNormalizer.normalizedEventID(watermark.eventID)
    } catch {
      resetFollowListStateInMemory()
    }
  }

  private func loadPersistedProfileMetadataState(ownerPubkey: String) {
    do {
      let profileMetadata = try accountStateStore.profileMetadata(ownerPubkey: ownerPubkey)
      currentProfileName = NostrProfileMetadata.normalizedChosenName(profileMetadata.chosenName)
      currentProfileMetadataContent = profileMetadata.content
      latestAppliedProfileMetadataCreatedAt = profileMetadata.createdAt
      latestAppliedProfileMetadataEventID = NostrValueNormalizer.normalizedEventID(
        profileMetadata.eventID
      )
    } catch {
      resetProfileMetadataStateInMemory()
    }
  }

  private func persistFollowListState(ownerPubkey: String, createdAt: Date, eventID: String?) {
    do {
      try accountStateStore.setFollowListWatermark(
        ownerPubkey: ownerPubkey,
        createdAt: createdAt,
        eventID: NostrValueNormalizer.normalizedEventID(eventID)
      )
    } catch {
      report(error: error)
    }
  }

  private func persistOwnProfileMetadataState(
    ownerPubkey: String,
    chosenName: String?,
    content: String?,
    createdAt: Date,
    eventID: String?
  ) {
    let normalizedChosenName = NostrProfileMetadata.normalizedChosenName(chosenName)
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)
    currentProfileName = normalizedChosenName
    currentProfileMetadataContent = content?.trimmingCharacters(in: .whitespacesAndNewlines)
    latestAppliedProfileMetadataCreatedAt = createdAt
    latestAppliedProfileMetadataEventID = normalizedEventID

    do {
      try accountStateStore.setProfileMetadata(
        ownerPubkey: ownerPubkey,
        chosenName: normalizedChosenName,
        content: currentProfileMetadataContent,
        createdAt: createdAt,
        eventID: normalizedEventID
      )
    } catch {
      report(error: error)
    }
  }

  private func preferredChosenName(for contact: ContactEntity) -> String? {
    let normalizedPubkey =
      NostrValueNormalizer.normalizedPubkeyHex(contact.targetPubkey) ?? contact.targetPubkey
    return remoteProfilesByPubkey[normalizedPubkey]?.chosenName
  }

  private func updateRemoteProfileSnapshot(
    pubkeyHex: String,
    chosenName: String?,
    createdAt: Date,
    eventID: String?
  ) {
    let normalizedPubkey = NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)
    if let existing = remoteProfilesByPubkey[normalizedPubkey],
      !NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: existing.updatedAt,
        currentEventID: existing.eventID,
        incomingUpdatedAt: createdAt,
        incomingEventID: normalizedEventID
      )
    {
      return
    }
    remoteProfilesByPubkey[normalizedPubkey] = KnownProfileSnapshot(
      chosenName: NostrProfileMetadata.normalizedChosenName(chosenName),
      updatedAt: createdAt,
      eventID: normalizedEventID
    )
    inFlightRemoteProfilePubkeys.remove(normalizedPubkey)
    pendingRemoteProfilePubkeys.remove(normalizedPubkey)
  }

  func requestRemoteProfilesIfNeeded(pubkeyHexes: [String]) {
    let missingPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes).filter {
      remoteProfilesByPubkey[$0] == nil && inFlightRemoteProfilePubkeys.contains($0) == false
    }
    guard !missingPubkeys.isEmpty else { return }
    guard canFetchRemoteProfilesInCurrentProcess else { return }
    submitRemoteProfileLookupIfPossible(missingPubkeys)
  }

  private func markRemoteProfilesInFlight(_ pubkeyHexes: [String]) {
    let normalizedPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes)
    guard !normalizedPubkeys.isEmpty else { return }
    inFlightRemoteProfilePubkeys.formUnion(normalizedPubkeys)
    let retryDelayNanoseconds = configuredRemoteProfileLookupRetryNanoseconds
    Task { [weak self, normalizedPubkeys] in
      try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self, normalizedPubkeys] in
        guard let self else { return }
        self.inFlightRemoteProfilePubkeys.subtract(normalizedPubkeys)
        let unresolvedPubkeys = normalizedPubkeys.filter { self.remoteProfilesByPubkey[$0] == nil }
        guard !unresolvedPubkeys.isEmpty else { return }
        self.pendingRemoteProfilePubkeys.formUnion(unresolvedPubkeys)
        self.retryPendingRemoteProfileRequestsIfNeeded()
      }
    }
  }

  private var canFetchRemoteProfilesInCurrentProcess: Bool {
    testingOverrides.requestProfileMetadata != nil || shouldFetchMetadataForCurrentProcess()
  }

  private func submitRemoteProfileLookupIfPossible(_ pubkeyHexes: [String]) {
    let normalizedPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes).filter {
      remoteProfilesByPubkey[$0] == nil
    }
    guard !normalizedPubkeys.isEmpty else { return }

    let didRequest: Bool
    if let requestProfileMetadata = testingOverrides.requestProfileMetadata {
      didRequest = requestProfileMetadata(normalizedPubkeys)
    } else {
      didRequest = nostrService.requestProfileMetadata(pubkeyHexes: normalizedPubkeys)
    }

    if didRequest {
      pendingRemoteProfilePubkeys.subtract(normalizedPubkeys)
      markRemoteProfilesInFlight(normalizedPubkeys)
    } else {
      pendingRemoteProfilePubkeys.formUnion(normalizedPubkeys)
    }
  }

  private func retryPendingRemoteProfileRequestsIfNeeded() {
    guard canFetchRemoteProfilesInCurrentProcess else { return }
    let pendingPubkeys = pendingRemoteProfilePubkeys.filter {
      remoteProfilesByPubkey[$0] == nil && inFlightRemoteProfilePubkeys.contains($0) == false
    }
    guard !pendingPubkeys.isEmpty else { return }
    submitRemoteProfileLookupIfPossible(Array(pendingPubkeys))
  }

  private func normalizedRelayURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "ws" || scheme == "wss",
      let host = components.host,
      !host.isEmpty
    else {
      return nil
    }
    return components.url
  }

  #if targetEnvironment(simulator)
    private func bootstrapSimulatorIfNeeded() {
      if identityService.keypair == nil {
        try? identityService.createNewIdentity()
      }

      guard let ownerPubkey = identityService.pubkeyHex else { return }

      let contactsDescriptor = FetchDescriptor<ContactEntity>()
      let contacts = ((try? modelContext.fetch(contactsDescriptor)) ?? []).filter {
        $0.ownerPubkey == ownerPubkey
      }
      let posts = ((try? modelContext.fetch(FetchDescriptor<SessionMessageEntity>())) ?? []).filter
      {
        $0.kind == .root && $0.ownerPubkey == ownerPubkey
      }

      var secondaryContact: ContactEntity
      if let firstContact = contacts.first {
        secondaryContact = firstContact
      } else {
        let secondaryKeypair = Keypair()
        let pubkeyHex =
          secondaryKeypair?.publicKey.hex
          ?? "0000000000000000000000000000000000000000000000000000000000000001"
        let contact = try? ContactEntity(
          ownerPubkey: ownerPubkey,
          targetPubkey: pubkeyHex,
          alias: "secondary test contact"
        )
        guard let contact else { return }
        modelContext.insert(contact)
        secondaryContact = contact
      }

      if posts.isEmpty, let myPubkey = identityService.pubkeyHex,
        PublicKey(hex: secondaryContact.targetPubkey) != nil
      {
        let peerPubkey = secondaryContact.targetPubkey
        let sessionID = "sim-\(ownerPubkey.prefix(12))"
        let sessionName = "simulator session"
        let seededAt = Date.now
        _ = try? messageStore.upsertSession(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          name: sessionName,
          createdByPubkey: myPubkey,
          updatedAt: seededAt
        )
        try? messageStore.applyMemberSnapshot(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          memberPubkeys: [myPubkey, peerPubkey],
          updatedAt: seededAt
        )
        let sampleURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let sampleEventID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let post = try? SessionMessageEntity(
          eventID: sampleEventID,
          ownerPubkey: ownerPubkey,
          conversationID: sessionID,
          rootID: sampleEventID,
          kind: .root,
          senderPubkey: myPubkey,
          url: sampleURL,
          note: "seeded simulator post",
          timestamp: .now,
          readAt: .now,
          linkType: URLClassifier.classify(sampleURL),
          metadataTitle: "sample link"
        )
        if let post {
          modelContext.insert(post)
        }
      }

      try? modelContext.save()
    }
  #endif
}
