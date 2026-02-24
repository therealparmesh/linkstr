import Foundation
import NostrSDK
import SwiftData

@MainActor
final class AppSession: ObservableObject {
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

  private struct RootPostDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let sessionID: String
    let recipientPubkeys: [String]
    let normalizedURL: String
    let normalizedNote: String?
  }

  private struct ReactionDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let sessionID: String
    let postID: String
    let emoji: String
    let isActive: Bool
    let recipientPubkeys: [String]
  }

  let identityService: IdentityService
  let nostrService: NostrDMService
  let modelContext: ModelContext
  private let contactStore: ContactStore
  private let relayStore: RelayStore
  private let messageStore: SessionMessageStore
  private let testHasConnectedRelaysOverride: (() -> Bool)?
  private let testDisableNostrStartupOverride: Bool?
  private let testRelaySendOverride: ((LinkstrPayload, [String]) async throws -> String)?
  private let testSkipNostrNetworkStartup: Bool
  private let noEnabledRelaysMessage =
    "no relays are enabled. enable at least one relay in settings."
  private let relayOfflineMessage = "you're offline. waiting for a relay connection."
  private let relayReadOnlyMessage =
    "connected relays are read-only. add a writable relay to send."
  private let relaySendTimeoutMessage = "couldn't reconnect to relays in time. try again."
  private var hasShownOfflineToastForCurrentOutage = false
  private var isForeground = false
  private var pendingMetadataStorageIDs: [String] = []
  private var pendingMetadataStorageHead = 0
  private var enqueuedMetadataStorageIDs = Set<String>()
  private var isProcessingMetadataQueue = false
  @Published private var relayRuntimeStatusByURL: [String: RelayRuntimeStatus] = [:]
  private var hasObservedHealthyRelayInCurrentForeground = false
  private let relayDisconnectGraceInterval: TimeInterval = 1.25
  private let foregroundRelayRestartCooldown: TimeInterval = 8
  private var lastForegroundRelayRestartAt: Date?
  private var latestAppliedFollowListCreatedAt: Date?
  private var latestAppliedFollowListEventID: String?

  @Published var composeError: String?
  @Published var pendingSessionNavigationID: String?
  @Published private(set) var hasIdentity = false
  @Published private(set) var didFinishBoot = false
  @Published private(set) var bootStatusMessage = "loading account…"

  init(
    modelContext: ModelContext,
    testDisableNostrStartupOverride: Bool? = nil,
    testHasConnectedRelaysOverride: (() -> Bool)? = nil,
    testRelaySendOverride: ((LinkstrPayload, [String]) async throws -> String)? = nil,
    testSkipNostrNetworkStartup: Bool = false
  ) {
    self.modelContext = modelContext
    self.testDisableNostrStartupOverride = testDisableNostrStartupOverride
    self.testHasConnectedRelaysOverride = testHasConnectedRelaysOverride
    self.testRelaySendOverride = testRelaySendOverride
    self.testSkipNostrNetworkStartup = testSkipNostrNetworkStartup
    self.identityService = IdentityService()
    self.nostrService = NostrDMService()
    self.contactStore = ContactStore(modelContext: modelContext)
    self.relayStore = RelayStore(modelContext: modelContext)
    self.messageStore = SessionMessageStore(modelContext: modelContext)
  }

  func boot() {
    didFinishBoot = false
    bootStatusMessage = "loading account…"
    defer { didFinishBoot = true }

    identityService.loadIdentity()
    refreshIdentityState()
    LocalNotificationService.shared.configure()
    if !isEnvironmentFlagEnabled("LINKSTR_SKIP_NOTIFICATION_PROMPT") {
      LocalNotificationService.shared.requestAuthorizationIfNeeded()
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
      try relayStore.ensureDefaultRelays()
      pruneRuntimeRelayStatusCache()
    } catch {
      composeError = error.localizedDescription
    }
    bootStatusMessage = "starting session…"
    handleAppDidBecomeActive()
    hydrateMissingMetadata()
  }

  func handleAppDidBecomeActive() {
    isForeground = true
    hasObservedHealthyRelayInCurrentForeground = false
    lastForegroundRelayRestartAt = nil
    startNostrIfPossible(forceRestart: true)
  }

  func handleAppDidLeaveForeground() {
    isForeground = false
    hasObservedHealthyRelayInCurrentForeground = false
    lastForegroundRelayRestartAt = nil
  }

  private func report(error: Error) {
    composeError = error.localizedDescription
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
    hasShownOfflineToastForCurrentOutage = false
    if composeError == relayOfflineMessage {
      composeError = nil
    }
  }

  private func showOfflineToastForCurrentOutageIfNeeded() {
    // Don't warn while startup/reconnect is still in the initial connection phase.
    guard hasObservedHealthyRelayInCurrentForeground else { return }
    guard !hasShownOfflineToastForCurrentOutage else { return }
    composeError = relayOfflineMessage
    hasShownOfflineToastForCurrentOutage = true
  }

  private func clearRelaySendBlockingErrorIfPresent() {
    if composeError == relayOfflineMessage
      || composeError == noEnabledRelaysMessage
      || composeError == relayReadOnlyMessage
    {
      composeError = nil
    }
  }

  private func hasConnectedRelays() -> Bool {
    if let testHasConnectedRelaysOverride {
      return testHasConnectedRelaysOverride()
    }
    return nostrService.hasConnectedRelays()
  }

  func relayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    if relay.isEnabled == false {
      return .disconnected
    }
    return effectiveRelayStatus(for: relay)
  }

  func relayErrorMessage(for relay: RelayEntity) -> String? {
    guard relay.isEnabled else { return nil }
    let runtime = relayRuntimeStatusByURL[relay.url]?.message
    let trimmedRuntime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedRuntime.isEmpty {
      return trimmedRuntime
    }
    let persisted = relay.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return persisted.isEmpty ? nil : persisted
  }

  func connectedRelayCount(for relays: [RelayEntity]) -> Int {
    relays.count { relay in
      relay.isEnabled
        && (relayStatus(for: relay) == .connected || relayStatus(for: relay) == .readOnly)
    }
  }

  func scopedContacts(from contacts: [ContactEntity]) -> [ContactEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return
      contacts
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  func scopedMessages(from messages: [SessionMessageEntity]) -> [SessionMessageEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return messages.filter { $0.ownerPubkey == ownerPubkey }
  }

  func scopedSessions(from sessions: [SessionEntity]) -> [SessionEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return
      sessions
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  func scopedSessionMembers(from members: [SessionMemberEntity]) -> [SessionMemberEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return members.filter { $0.ownerPubkey == ownerPubkey }
  }

  func scopedReactions(from reactions: [SessionReactionEntity]) -> [SessionReactionEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return reactions.filter { $0.ownerPubkey == ownerPubkey }
  }

  func canManageMembers(for session: SessionEntity) -> Bool {
    guard let myPubkey = identityService.pubkeyHex else { return false }
    return session.createdByPubkey == myPubkey
  }

  private func effectiveRelayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    if let runtimeStatus = relayRuntimeStatusByURL[relay.url]?.status {
      return runtimeStatus
    }
    return relay.status
  }

  private func updateRuntimeRelayStatus(
    relayURL: String,
    status: RelayHealthStatus,
    message: String?
  ) {
    if status == .connected || status == .readOnly {
      hasObservedHealthyRelayInCurrentForeground = true
      lastForegroundRelayRestartAt = nil
    }

    let now = Date()
    let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let existing = relayRuntimeStatusByURL[relayURL],
      existing.status == .connected || existing.status == .readOnly,
      status == .disconnected,
      trimmedMessage?.isEmpty != false,
      now.timeIntervalSince(existing.updatedAt) < relayDisconnectGraceInterval
    {
      // Keep healthy status briefly while relay pool restarts to avoid flicker.
      return
    }

    relayRuntimeStatusByURL[relayURL] = RelayRuntimeStatus(
      status: status,
      message: (trimmedMessage?.isEmpty == false) ? trimmedMessage : nil,
      updatedAt: now
    )
    persistRelayRuntimeStatus(
      relayURL: relayURL,
      status: status,
      message: trimmedMessage
    )
  }

  private func persistRelayRuntimeStatus(
    relayURL: String,
    status: RelayHealthStatus,
    message: String?
  ) {
    let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let persistedMessage = (normalizedMessage?.isEmpty == false) ? normalizedMessage : nil

    do {
      let relays = try relayStore.fetchRelays()
      guard let relay = relays.first(where: { $0.url == relayURL }) else { return }

      var didChange = false
      if relay.status != status {
        relay.status = status
        didChange = true
      }
      if relay.lastError != persistedMessage {
        relay.lastError = persistedMessage
        didChange = true
      }

      if didChange {
        try modelContext.save()
      }
    } catch {
      // Keep runtime relay updates resilient even if local persistence fails.
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
      clearOfflineToastIfPresent()
    case .connecting:
      return
    case .offline:
      showOfflineToastForCurrentOutageIfNeeded()
    case .noEnabledRelays:
      return
    }
  }

  private func maybeForceRestartRelaysForForegroundRecovery(triggeredBy status: RelayHealthStatus) {
    guard isForeground else { return }
    guard status == .failed || status == .disconnected else { return }
    guard identityService.keypair != nil else { return }
    guard !shouldDisableNostrStartupForCurrentProcess() else { return }

    let enabledRelays: [RelayEntity]
    do {
      enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    } catch {
      return
    }

    guard !enabledRelays.isEmpty else { return }
    guard relayConnectivityState(for: enabledRelays) == .offline else { return }

    let now = Date()
    if let lastForegroundRelayRestartAt,
      now.timeIntervalSince(lastForegroundRelayRestartAt) < foregroundRelayRestartCooldown
    {
      return
    }

    lastForegroundRelayRestartAt = now
    startNostrIfPossible(forceRestart: true)
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

    if hasConnectedRelays() {
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
      return .blocked(message: noEnabledRelaysMessage)
    case .readOnly:
      return .blocked(message: relayReadOnlyMessage)
    case .online, .connecting, .offline:
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
    if let testDisableNostrStartupOverride {
      return testDisableNostrStartupOverride
    }

    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return false }
    return !isEnvironmentFlagEnabled("LINKSTR_ENABLE_NOSTR_IN_TESTS")
  }

  private func shouldFetchMetadataForCurrentProcess() -> Bool {
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return true }
    return isEnvironmentFlagEnabled("LINKSTR_ENABLE_METADATA_IN_TESTS")
  }

  func ensureIdentity() {
    if identityService.keypair == nil {
      do {
        try identityService.createNewIdentity()
        refreshIdentityState()
        composeError = nil
        startNostrIfPossible()
      } catch {
        composeError = error.localizedDescription
      }
    } else {
      refreshIdentityState()
    }
  }

  func importNsec(_ nsec: String) {
    do {
      try identityService.importNsec(nsec)
      refreshIdentityState()
      composeError = nil
      startNostrIfPossible()
    } catch {
      composeError = error.localizedDescription
    }
  }

  func logout(clearLocalData: Bool) {
    let ownerPubkey = identityService.pubkeyHex
    nostrService.stop()

    do {
      try identityService.clearIdentity()
    } catch {
      composeError = error.localizedDescription
      return
    }
    refreshIdentityState()
    pendingMetadataStorageIDs.removeAll()
    pendingMetadataStorageHead = 0
    enqueuedMetadataStorageIDs.removeAll()
    isProcessingMetadataQueue = false
    relayRuntimeStatusByURL.removeAll()
    pendingSessionNavigationID = nil
    latestAppliedFollowListCreatedAt = nil
    latestAppliedFollowListEventID = nil

    if let ownerPubkey, clearLocalData {
      clearCachedVideos(ownerPubkey: ownerPubkey)
      clearMessageCache(ownerPubkey: ownerPubkey)
      clearAllContacts(ownerPubkey: ownerPubkey)
      try? LocalDataCrypto.shared.clearKey(ownerPubkey: ownerPubkey)
    }

    composeError = nil
  }

  private func refreshIdentityState() {
    hasIdentity = identityService.keypair != nil
  }

  func startNostrIfPossible(forceRestart: Bool = false) {
    guard let keypair = identityService.keypair else { return }
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    if forceRestart {
      // iOS may suspend sockets while backgrounded; on foreground always rebuild the relay
      // session so send-gating reflects fresh connection state instead of stale sockets.
      nostrService.stop()
    }

    if isRunningTests, testSkipNostrNetworkStartup {
      relayRuntimeStatusByURL.removeAll()
      nostrService.start(
        keypair: keypair,
        relayURLs: [],
        onIncoming: { _ in },
        onRelayStatus: { _, _, _ in }
      )
      return
    }

    if shouldDisableNostrStartupForCurrentProcess() {
      // Keep local send paths available in tests without opening relay connections.
      relayRuntimeStatusByURL.removeAll()
      nostrService.start(
        keypair: keypair,
        relayURLs: [],
        onIncoming: { _ in },
        onRelayStatus: { _, _, _ in }
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
    if relayURLs.isEmpty {
      nostrService.stop()
      relayRuntimeStatusByURL.removeAll()
      composeError = noEnabledRelaysMessage
      hasShownOfflineToastForCurrentOutage = false
      return
    }
    if composeError == noEnabledRelaysMessage {
      composeError = nil
    }
    relayRuntimeStatusByURL = relayRuntimeStatusByURL.filter { relayURLs.contains($0.key) }

    nostrService.start(
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
          self.maybeForceRestartRelaysForForegroundRecovery(triggeredBy: status)
        }
      },
      onFollowList: { [weak self] followList in
        Task { @MainActor in
          self?.persistIncomingFollowList(followList)
        }
      }
    )
  }

  @discardableResult
  func createSessionAwaitingRelay(
    name: String,
    memberNPubs: [String],
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      composeError = "enter a session name."
      return false
    }

    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to create sessions."
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
      if shouldDisableNostrStartupForCurrentProcess() == false {
        membershipEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: payload,
          recipientPubkeyHexes: members
        )
      } else {
        membershipEventID = makeLocalEventID()
      }

      let updatedAt = now
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: normalizedName,
        createdByPubkey: keypair.publicKey.hex,
        updatedAt: updatedAt
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
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
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage session members."
      return false
    }

    guard canManageMembers(for: session) else {
      composeError = "only the session creator can manage members."
      return false
    }

    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    let members = normalizedMemberPubkeys(
      fromNPubs: memberNPubs,
      myPubkey: keypair.publicKey.hex
    )
    let now = Date.now
    let timestamp = Int64(now.timeIntervalSince1970)
    let payload = LinkstrPayload(
      conversationID: session.sessionID,
      rootID: makeLocalEventID(),
      kind: .sessionMembers,
      url: nil,
      note: nil,
      timestamp: timestamp,
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
      if shouldDisableNostrStartupForCurrentProcess() == false {
        membershipEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: payload,
          recipientPubkeyHexes: updateRecipients
        )
      } else {
        membershipEventID = makeLocalEventID()
      }

      let updatedAt = now
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID,
        name: session.name,
        createdByPubkey: session.createdByPubkey,
        updatedAt: updatedAt,
        isArchived: session.isArchived
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID,
        memberPubkeys: members,
        updatedAt: updatedAt,
        eventID: membershipEventID
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
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    if shouldDisableNostrStartupForCurrentProcess() {
      return createPostInSession(url: url, note: note, sessionID: session.sessionID)
    }
    return await createPostAwaitingRelayDelivery(url: url, note: note, sessionID: session.sessionID)
  }

  @discardableResult
  private func createPostInSession(url: String, note: String?, sessionID: String) -> Bool {
    guard let draft = makeRootPostDraft(url: url, note: note, sessionID: sessionID) else {
      return false
    }

    do {
      // Test-only local send path when relay startup is disabled in-process.
      let eventID = makeLocalEventID()
      try persistSentRootPost(draft, eventID: eventID)
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
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    guard let draft = makeReactionDraft(emoji: emoji, post: post) else {
      return false
    }

    do {
      let reactionEventID: String
      if shouldDisableNostrStartupForCurrentProcess() == false {
        reactionEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: draft.payload,
          recipientPubkeyHexes: draft.recipientPubkeys
        )
      } else {
        reactionEventID = makeLocalEventID()
      }
      try persistReactionState(draft, eventID: reactionEventID)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func createPostAwaitingRelayDelivery(
    url: String,
    note: String?,
    sessionID: String
  ) async -> Bool {
    guard let draft = makeRootPostDraft(url: url, note: note, sessionID: sessionID) else {
      return false
    }

    do {
      let eventID = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      )
      try persistSentRootPost(draft, eventID: eventID)
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

    let recipientPubkeys: [String]
    do {
      guard
        try messageStore.isMemberActive(
          sessionID: post.conversationID,
          ownerPubkey: ownerPubkey,
          memberPubkey: keypair.publicKey.hex,
          at: .now
        )
      else {
        composeError = "you're no longer a member of this session."
        return nil
      }

      recipientPubkeys = try activeMemberPubkeys(
        sessionID: post.conversationID,
        ownerPubkey: ownerPubkey
      )
      guard recipientPubkeys.contains(keypair.publicKey.hex) else {
        composeError = "you're no longer a member of this session."
        return nil
      }
    } catch {
      composeError = error.localizedDescription
      return nil
    }

    let existingReactions =
      (try? messageStore.reactions(
        ownerPubkey: ownerPubkey,
        sessionID: post.conversationID
      )) ?? []
    let currentlyActive = existingReactions.contains { reaction in
      reaction.postID == post.rootID
        && reaction.emoji == normalizedEmoji
        && reaction.senderMatches(keypair.publicKey.hex)
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
      sessionID: post.conversationID,
      postID: post.rootID,
      emoji: normalizedEmoji,
      isActive: nextState,
      recipientPubkeys: recipientPubkeys
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

    let recipientPubkeys: [String]
    do {
      guard
        try messageStore.isMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: keypair.publicKey.hex,
          at: .now
        )
      else {
        composeError = "you're no longer a member of this session."
        return nil
      }
      recipientPubkeys = try activeMemberPubkeys(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey
      )
      guard recipientPubkeys.contains(keypair.publicKey.hex) else {
        composeError = "you're no longer a member of this session."
        return nil
      }
    } catch {
      composeError = error.localizedDescription
      return nil
    }
    guard !recipientPubkeys.isEmpty else {
      composeError = "session has no members. add members before sending."
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
      sessionID: sessionID,
      recipientPubkeys: recipientPubkeys,
      normalizedURL: normalizedURL,
      normalizedNote: normalizedNote
    )
  }

  private func persistSentRootPost(_ draft: RootPostDraft, eventID: String) throws {
    _ = try messageStore.upsertSession(
      ownerPubkey: draft.ownerPubkey,
      sessionID: draft.sessionID,
      name: existingSessionName(for: draft.sessionID, ownerPubkey: draft.ownerPubkey),
      createdByPubkey: draft.senderPubkey,
      updatedAt: .now
    )
    let message = try SessionMessageEntity(
      eventID: eventID,
      ownerPubkey: draft.ownerPubkey,
      conversationID: draft.sessionID,
      rootID: eventID,
      kind: .root,
      senderPubkey: draft.senderPubkey,
      receiverPubkey: draft.ownerPubkey,
      url: draft.normalizedURL,
      note: draft.normalizedNote,
      timestamp: .now,
      readAt: .now,
      linkType: URLClassifier.classify(draft.normalizedURL)
    )
    try messageStore.insert(message)
    enqueueMetadataRefresh(for: message)
  }

  private func persistReactionState(_ draft: ReactionDraft, eventID: String) throws {
    try messageStore.upsertReaction(
      ownerPubkey: draft.ownerPubkey,
      sessionID: draft.sessionID,
      postID: draft.postID,
      emoji: draft.emoji,
      senderPubkey: draft.senderPubkey,
      isActive: draft.isActive,
      updatedAt: .now,
      eventID: eventID
    )
  }

  private func sendPayloadAwaitingRelayAcceptance(
    payload: LinkstrPayload,
    recipientPubkeyHexes: [String]
  ) async throws -> String {
    if let testRelaySendOverride {
      guard !recipientPubkeyHexes.isEmpty else {
        throw NostrServiceError.invalidPubkey
      }
      return try await testRelaySendOverride(payload, recipientPubkeyHexes)
    }
    return try await nostrService.sendAwaitingRelayAcceptance(
      payload: payload,
      toMany: recipientPubkeyHexes
    )
  }

  private func normalizedMemberPubkeys(fromNPubs memberNPubs: [String], myPubkey: String)
    -> [String]
  {
    var members: [String] = []
    var seen = Set<String>()

    func appendMember(_ pubkeyHex: String) {
      guard PublicKey(hex: pubkeyHex) != nil else { return }
      guard !seen.contains(pubkeyHex) else { return }
      seen.insert(pubkeyHex)
      members.append(pubkeyHex)
    }

    appendMember(myPubkey)
    for npub in memberNPubs {
      guard let member = PublicKey(npub: npub.trimmingCharacters(in: .whitespacesAndNewlines))
      else {
        continue
      }
      appendMember(member.hex)
    }

    return members
  }

  private func activeMemberPubkeys(sessionID: String, ownerPubkey: String) throws -> [String] {
    let members = try messageStore.members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: true
    ).map(\.memberPubkey)
    return dedupedValidPubkeys(members)
  }

  private func dedupedValidPubkeys(_ pubkeyHexes: [String]) -> [String] {
    var deduped: [String] = []
    var seen = Set<String>()

    func appendIfValid(_ pubkeyHex: String) {
      guard PublicKey(hex: pubkeyHex) != nil else { return }
      guard !seen.contains(pubkeyHex) else { return }
      seen.insert(pubkeyHex)
      deduped.append(pubkeyHex)
    }

    pubkeyHexes.forEach { appendIfValid($0) }
    return deduped
  }

  private func mergedPubkeys(_ first: [String], _ second: [String]) -> [String] {
    dedupedValidPubkeys(first + second)
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

  @discardableResult
  func addContact(
    npub: String,
    alias: String,
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }

    let targetPubkey: String
    do {
      targetPubkey = try contactStore.normalizeFollowTarget(npub)
      if contactStore.hasContact(ownerPubkey: ownerPubkey, withTargetPubkey: targetPubkey) {
        composeError = "this contact is already in your list."
        return false
      }
    } catch {
      report(error: error)
      return false
    }

    let normalizedAlias = contactStore.normalizeAlias(alias)

    let nextFollowedPubkeys: [String]
    do {
      var set = Set(try contactStore.followedPubkeys(ownerPubkey: ownerPubkey))
      set.insert(targetPubkey)
      nextFollowedPubkeys = Array(set).sorted()
    } catch {
      report(error: error)
      return false
    }

    if shouldDisableNostrStartupForCurrentProcess() == false {
      guard
        await awaitRelayReadyForSend(
          timeoutSeconds: timeoutSeconds,
          pollIntervalSeconds: pollIntervalSeconds
        )
      else {
        return false
      }
      startNostrIfPossible()

      do {
        _ = try await nostrService.publishFollowListAwaitingRelayAcceptance(
          followedPubkeyHexes: nextFollowedPubkeys
        )
      } catch {
        report(error: error)
        return false
      }
    }

    do {
      try contactStore.replaceFollowedPubkeys(
        ownerPubkey: ownerPubkey,
        pubkeyHexes: nextFollowedPubkeys
      )
      if let normalizedAlias {
        try contactStore.updateAlias(
          ownerPubkey: ownerPubkey,
          targetPubkey: targetPubkey,
          alias: normalizedAlias
        )
      }
      latestAppliedFollowListCreatedAt = .now
      latestAppliedFollowListEventID = nil
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
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
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
      var set = Set(try contactStore.followedPubkeys(ownerPubkey: ownerPubkey))
      set.remove(contact.targetPubkey)
      nextFollowedPubkeys = Array(set).sorted()
    } catch {
      report(error: error)
      return false
    }

    if shouldDisableNostrStartupForCurrentProcess() == false {
      guard
        await awaitRelayReadyForSend(
          timeoutSeconds: timeoutSeconds,
          pollIntervalSeconds: pollIntervalSeconds
        )
      else {
        return false
      }
      startNostrIfPossible()

      do {
        _ = try await nostrService.publishFollowListAwaitingRelayAcceptance(
          followedPubkeyHexes: nextFollowedPubkeys
        )
      } catch {
        report(error: error)
        return false
      }
    }

    do {
      try contactStore.replaceFollowedPubkeys(
        ownerPubkey: ownerPubkey,
        pubkeyHexes: nextFollowedPubkeys
      )
      latestAppliedFollowListCreatedAt = .now
      latestAppliedFollowListEventID = nil
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func clearAllContacts(ownerPubkey: String) {
    do {
      try contactStore.clearAllContacts(ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
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
    startNostrIfPossible()
    return true
  }

  private func clearMessageCache(ownerPubkey: String) {
    do {
      try messageStore.clearAllSessionData(ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func clearCachedVideos() {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage local storage."
      return
    }
    clearCachedVideos(ownerPubkey: ownerPubkey)
  }

  private func clearCachedVideos(ownerPubkey: String) {
    do {
      try messageStore.clearCachedVideos(ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func contactName(for pubkeyHex: String, contacts: [ContactEntity]) -> String {
    contactStore.contactName(for: pubkeyHex, contacts: contacts)
  }

  private func persistIncomingFollowList(_ incoming: ReceivedFollowList) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    guard incoming.authorPubkey == ownerPubkey else { return }

    if let latestCreatedAt = latestAppliedFollowListCreatedAt {
      if incoming.createdAt < latestCreatedAt {
        return
      }
      if incoming.createdAt == latestCreatedAt {
        let incomingEventID = normalizedEventIDToken(incoming.eventID)
        let latestEventID = normalizedEventIDToken(latestAppliedFollowListEventID)
        guard !incomingEventID.isEmpty else { return }
        if !latestEventID.isEmpty, incomingEventID <= latestEventID {
          return
        }
      }
    }

    do {
      try contactStore.replaceFollowedPubkeys(
        ownerPubkey: ownerPubkey,
        pubkeyHexes: incoming.followedPubkeys
      )
      latestAppliedFollowListCreatedAt = incoming.createdAt
      let incomingEventID = normalizedEventIDToken(incoming.eventID)
      latestAppliedFollowListEventID = incomingEventID.isEmpty ? nil : incomingEventID
    } catch {
      report(error: error)
    }
  }

  #if DEBUG
    func ingestForTesting(_ incoming: ReceivedDirectMessage) {
      persistIncoming(incoming)
    }

    func ingestFollowListForTesting(_ incoming: ReceivedFollowList) {
      persistIncomingFollowList(incoming)
    }
  #endif

  private func persistIncoming(_ incoming: ReceivedDirectMessage) {
    switch incoming.payload.kind {
    case .sessionCreate:
      persistIncomingSessionCreate(incoming)
    case .sessionMembers:
      persistIncomingSessionMembers(incoming)
    case .reaction:
      persistIncomingReaction(incoming)
    case .root:
      persistIncomingRootPost(incoming)
    }
  }

  private func persistIncomingSessionCreate(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return
    }
    guard members.contains(incoming.senderPubkey) else { return }
    guard members.contains(ownerPubkey) else { return }

    do {
      let existing = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)
      if let existing, existing.createdByPubkey != incoming.senderPubkey {
        return
      }

      let incomingName = incoming.payload.sessionName?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let sessionName =
        (incomingName?.isEmpty == false)
        ? incomingName!
        : (existing?.name ?? existingSessionName(for: sessionID, ownerPubkey: ownerPubkey))
      let createdByPubkey = existing?.createdByPubkey ?? incoming.senderPubkey

      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: sessionName,
        createdByPubkey: createdByPubkey,
        updatedAt: incoming.createdAt,
        isArchived: existing?.isArchived
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkeys: members,
        updatedAt: incoming.createdAt,
        eventID: incoming.eventID
      )
    } catch {
      report(error: error)
    }
  }

  private func persistIncomingSessionMembers(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return
    }

    do {
      let existing = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)
      guard let existing else { return }
      guard existing.createdByPubkey == incoming.senderPubkey else {
        return
      }
      guard members.contains(existing.createdByPubkey) else { return }

      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: existing.name,
        createdByPubkey: existing.createdByPubkey,
        updatedAt: incoming.createdAt,
        isArchived: existing.isArchived
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkeys: members,
        updatedAt: incoming.createdAt,
        eventID: incoming.eventID
      )
    } catch {
      report(error: error)
    }
  }

  private func persistIncomingReaction(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    guard let isActive = incoming.payload.reactionActive else { return }
    let emoji = incoming.payload.emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !emoji.isEmpty else { return }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    let postID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !postID.isEmpty else { return }
    guard
      inboundMembershipIsActive(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        senderPubkey: incoming.senderPubkey,
        timestamp: incoming.createdAt
      )
    else {
      return
    }

    do {
      guard
        try messageStore.hasRootPost(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          rootID: postID
        )
      else {
        return
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
    } catch {
      report(error: error)
      return
    }
  }

  private func persistIncomingRootPost(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    do {
      let storageID = SessionMessageEntity.storageID(
        ownerPubkey: ownerPubkey,
        eventID: incoming.eventID
      )
      if let existing = try messageStore.message(storageID: storageID) {
        if existing.kind == .root {
          enqueueMetadataRefresh(for: existing)
        }
        return
      }
    } catch {
      report(error: error)
      return
    }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    guard
      inboundMembershipIsActive(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        senderPubkey: incoming.senderPubkey,
        timestamp: incoming.createdAt
      )
    else {
      return
    }
    let payloadRootID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !payloadRootID.isEmpty, payloadRootID != incoming.eventID {
      return
    }
    let canonicalPostID = incoming.eventID
    guard let payloadURL = incoming.payload.url,
      let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: payloadURL)
    else {
      return
    }

    let isEchoedOutgoing = identityService.pubkeyHex == incoming.senderPubkey
    let existingSession: SessionEntity
    do {
      guard let session = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey)
      else {
        return
      }
      existingSession = session
    } catch {
      report(error: error)
      return
    }

    do {
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: existingSession.name,
        createdByPubkey: existingSession.createdByPubkey,
        updatedAt: incoming.createdAt,
        isArchived: existingSession.isArchived
      )
    } catch {
      report(error: error)
      return
    }

    let message: SessionMessageEntity
    do {
      message = try SessionMessageEntity(
        eventID: incoming.eventID,
        ownerPubkey: ownerPubkey,
        conversationID: sessionID,
        rootID: canonicalPostID,
        kind: .root,
        senderPubkey: incoming.senderPubkey,
        receiverPubkey: incoming.receiverPubkey,
        url: normalizedURL,
        note: incoming.payload.note,
        timestamp: incoming.createdAt,
        readAt: isEchoedOutgoing ? incoming.createdAt : nil,
        linkType: URLClassifier.classify(normalizedURL)
      )
    } catch {
      report(error: error)
      return
    }

    do {
      try messageStore.insert(message)
    } catch {
      report(error: error)
      return
    }

    notifyForIncomingMessage(message)
    enqueueMetadataRefresh(for: message)
  }

  private func inboundMembershipIsActive(
    sessionID: String,
    ownerPubkey: String,
    senderPubkey: String,
    timestamp: Date
  ) -> Bool {
    guard let myPubkey = identityService.pubkeyHex else { return false }

    do {
      guard
        try messageStore.isMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: senderPubkey,
          at: .now
        )
      else {
        return false
      }
      guard
        try messageStore.isMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: myPubkey,
          at: .now
        )
      else {
        return false
      }
      guard
        try messageStore.isMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: senderPubkey,
          at: timestamp
        )
      else {
        return false
      }
      guard
        try messageStore.isMemberActive(
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

  private func notifyForIncomingMessage(_ message: SessionMessageEntity) {
    guard let myPubkey = identityService.pubkeyHex, message.senderPubkey != myPubkey else {
      return
    }

    let contacts = (try? contactStore.fetchContacts(ownerPubkey: myPubkey)) ?? []
    let senderName = contactName(for: message.senderPubkey, contacts: contacts)
    LocalNotificationService.shared.postIncomingPostNotification(
      senderName: senderName,
      url: message.url,
      note: message.note,
      eventID: message.eventID,
      conversationID: message.conversationID
    )
  }

  private func hydrateMissingMetadata() {
    guard shouldFetchMetadataForCurrentProcess() else { return }
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    do {
      let roots = try messageStore.rootMessages(ownerPubkey: ownerPubkey)
      let sortedRoots = roots.sorted { $0.timestamp > $1.timestamp }
      for message in sortedRoots where needsMetadataRefresh(message) {
        enqueueMetadataRefresh(for: message)
      }
    } catch {
      report(error: error)
    }
  }

  private func enqueueMetadataRefresh(for message: SessionMessageEntity) {
    guard shouldFetchMetadataForCurrentProcess() else { return }
    guard message.kind == .root else { return }
    guard message.url != nil else { return }
    guard needsMetadataRefresh(message) else { return }

    let storageID = message.storageID
    guard !enqueuedMetadataStorageIDs.contains(storageID) else { return }
    enqueuedMetadataStorageIDs.insert(storageID)
    pendingMetadataStorageIDs.append(storageID)
    processMetadataQueueIfNeeded()
  }

  private func processMetadataQueueIfNeeded() {
    guard !isProcessingMetadataQueue else { return }
    isProcessingMetadataQueue = true

    Task { @MainActor in
      while pendingMetadataStorageHead < pendingMetadataStorageIDs.count {
        let storageID = pendingMetadataStorageIDs[pendingMetadataStorageHead]
        pendingMetadataStorageHead += 1
        defer {
          enqueuedMetadataStorageIDs.remove(storageID)
        }

        do {
          guard let message = try messageStore.message(storageID: storageID) else { continue }
          try await refreshMetadata(for: message)
        } catch {
          report(error: error)
        }
      }

      pendingMetadataStorageIDs.removeAll(keepingCapacity: true)
      pendingMetadataStorageHead = 0
      isProcessingMetadataQueue = false
    }
  }

  private func refreshMetadata(for message: SessionMessageEntity) async throws {
    guard let url = message.url else { return }
    guard needsMetadataRefresh(message) else { return }

    let preview = await URLMetadataService.shared.fetchPreview(for: url)
    guard let preview else { return }

    let currentTitle = normalizedMetadataTitle(message.metadataTitle)
    let previewTitle = normalizedMetadataTitle(preview.title)
    let resolvedTitle = previewTitle ?? currentTitle

    let currentThumbnail = normalizedThumbnailPath(message.thumbnailURL)
    let previewThumbnail = normalizedThumbnailPath(preview.thumbnailPath)
    let resolvedThumbnail: String?
    if let previewThumbnail {
      resolvedThumbnail = previewThumbnail
    } else if let currentThumbnail, FileManager.default.fileExists(atPath: currentThumbnail) {
      resolvedThumbnail = currentThumbnail
    } else {
      resolvedThumbnail = nil
    }

    guard resolvedTitle != currentTitle || resolvedThumbnail != currentThumbnail else {
      return
    }

    try message.setMetadata(title: resolvedTitle, thumbnailURL: resolvedThumbnail)
    try modelContext.save()
  }

  private func needsMetadataRefresh(_ message: SessionMessageEntity) -> Bool {
    guard message.kind == .root else { return false }
    guard message.url != nil else { return false }

    let hasTitle = normalizedMetadataTitle(message.metadataTitle) != nil
    if !hasTitle {
      return true
    }

    guard let thumbnailPath = normalizedThumbnailPath(message.thumbnailURL) else {
      return false
    }
    return !FileManager.default.fileExists(atPath: thumbnailPath)
  }

  private func normalizedMetadataTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizedThumbnailPath(_ path: String?) -> String? {
    guard let path else { return nil }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizedEventIDToken(_ eventID: String?) -> String {
    guard let eventID else { return "" }
    return eventID.trimmingCharacters(in: .whitespacesAndNewlines)
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
          receiverPubkey: peerPubkey,
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
